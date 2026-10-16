const std = @import("std");

/// Version baked into the generated `slang-tag-version.h`. The upstream build
/// derives this from git tags; there are none in a plain checkout, so we pin a
/// fallback and allow overriding through `-Dslang-version=...`.
const default_slang_version = "0.0.0";

/// Optimization used for build-time-only tools (the generators and the bootstrap
/// compiler). Their output is generated data or a precompiled core module, so
/// the consumer's chosen mode has no bearing on the shipped library's runtime;
/// always building them optimized keeps the build itself fast even when the
/// consumer selects Debug. `_DEBUG` for these tools still follows the external
/// mode so it stays consistent with the core libraries they link against.
const build_time_optimize: std.builtin.OptimizeMode = .ReleaseFast;

/// Target used for the build-time host tools (the generators and the bootstrap
/// compiler) and the libraries they link.
///
/// These tools are compiled and then *executed* during the build, so they must
/// run on the build host. By default they use the consumer target's libc. When
/// `host_musl_static` is enabled, on Linux they are instead built against musl
/// so that, combined with the static linkage from `hostLinkage`, they become
/// fully static executables that run even where the consumer target's dynamic
/// loader is unavailable (for example sandboxed/Nix builds, where spawning the
/// tool otherwise fails with an opaque `FileNotFound`). musl is used because it
/// ships with Zig and needs no external sysroot; glibc cannot be used because
/// NixOS does not provide its static archives (`libc.a`).
fn hostTarget(b: *std.Build, target: std.Build.ResolvedTarget, musl_static: bool) std.Build.ResolvedTarget {
    if (!musl_static) return target;
    if (target.result.os.tag != .linux) return target;
    var query = target.query;
    query.abi = .musl;
    return b.resolveTargetQuery(query);
}

/// Roots of the third-party source trees that upstream keeps as git submodules
/// under `external/`.
const External = struct {
    unordered_dense: std.Build.LazyPath,
    fast_float: std.Build.LazyPath,
    spirv_headers: std.Build.LazyPath,
    cmark: std.Build.LazyPath,
    miniz: std.Build.LazyPath,
    lz4: std.Build.LazyPath,
    lua: std.Build.LazyPath,
    glslang: std.Build.LazyPath,
    spirv_tools: std.Build.LazyPath,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check = b.step("check", "Compile intermediate libraries without linking the final artifact");

    // Resolve the third-party sources. This returns `null` when a needed source
    // tree is neither checked out under `external/` nor fetched yet; returning
    // here lets Zig fetch the pending lazy dependencies (declared in
    // build.zig.zon) and run the configure phase again with them available.
    const external = resolveExternal(b) orelse return;
    const lua_include = luaIncludeDir(b, external);

    // Whether the build-time host tools are linked statically against musl
    // instead of using the consumer target's libc. See `hostTarget`.
    const host_musl_static = b.option(
        bool,
        "host_musl_static",
        "Build the build-time host tools (generators and bootstrap) as static musl executables instead of using the default libc",
    ) orelse false;

    // Target for the build-time host tools and the libraries they link.
    const host_target = hostTarget(b, target, host_musl_static);

    // miniz.h includes a generated "miniz_export.h" (normally produced by
    // CMake's generate_export_header). For a static build the export macro
    // expands to nothing, so provide a minimal replacement.
    const miniz_export = b.addWriteFiles();
    _ = miniz_export.add("miniz_export.h",
        \\#ifndef MINIZ_EXPORT
        \\#define MINIZ_EXPORT
        \\#endif
        \\
    );

    const miniz = addMiniz(b, target, optimize, external.miniz, miniz_export.getDirectory());
    const miniz_host = addMiniz(b, host_target, build_time_optimize, external.miniz, miniz_export.getDirectory());

    // cmark's config.h is generated from a template that only toggles
    // CMARK_THREADING (off by default upstream; Slang does not enable it).
    const cmark_config = b.addWriteFiles();
    _ = cmark_config.add("config.h",
        \\#ifndef CMARK_CONFIG_H
        \\#define CMARK_CONFIG_H
        \\#define CMARK_THREADING 0
        \\#endif
        \\
    );

    const lz4 = addLz4(b, target, optimize, external.lz4);
    const cmark = addCmark(b, target, optimize, external.cmark, cmark_config.getDirectory());
    const lz4_host = addLz4(b, host_target, build_time_optimize, external.lz4);
    const cmark_host = addCmark(b, host_target, build_time_optimize, external.cmark, cmark_config.getDirectory());

    // glslang + SPIRV-Tools and the `slang-glslang` module they back. The grammar
    // tables and glslang's `build_info.h` are the pre-generated copies checked
    // into the repository (external/spirv-tools-generated, external/glslang-generated),
    // so no Python or bison is required at build time.
    const spirv_tools_generated = b.path("external/spirv-tools-generated");
    const glslang_generated = b.path("external/glslang-generated");
    const spirv_tools = addSpirvTools(b, target, optimize, external.spirv_tools, spirv_tools_generated, external.spirv_headers);
    const glslang = addGlslang(b, target, optimize, external.glslang, glslang_generated, external.spirv_tools, spirv_tools_generated, external.spirv_headers);
    const slang_glslang = addSlangGlslang(b, target, optimize, glslang, spirv_tools, external);

    const version_header = b.addWriteFiles();
    _ = version_header.add("slang-tag-version.h", b.fmt(
        \\#define SLANG_TAG_VERSION "{s}"
        \\#define SLANG_VERSION_NUMERIC "{s}"
        \\
    , .{ default_slang_version, default_slang_version }));

    const core = addCore(b, target, optimize, external, miniz, lz4, miniz_export.getDirectory());
    const compiler_core = addCompilerCore(b, target, optimize, external, core, version_header.getDirectory());

    // Host variants, used only by the build-time tools/generators and the
    // bootstrap compiler. They are built for `host_target` so they can be
    // executed during the build.
    const core_host = addCore(b, host_target, build_time_optimize, external, miniz_host, lz4_host, miniz_export.getDirectory());
    const compiler_core_host = addCompilerCore(b, host_target, build_time_optimize, external, core_host, version_header.getDirectory());

    // Host tools compiled from the repository itself (the "generators").
    const embed_exe = addHostExecutable(b, host_target, optimize, external, lua_include, "slang-embed", &.{
        "tools/slang-embed/slang-embed.cpp",
    }, &.{core_host}, &.{});
    const generate_exe = addHostExecutable(b, host_target, optimize, external, lua_include, "slang-generate", &.{
        "tools/slang-generate/main.cpp",
    }, &.{core_host}, &.{});
    const capability_exe = addHostExecutable(b, host_target, optimize, external, lua_include, "slang-capability-generator", &.{
        "tools/slang-capability-generator/capability-generator-main.cpp",
    }, &.{compiler_core_host}, &.{});
    const lookup_exe = addHostExecutable(b, host_target, optimize, external, lua_include, "slang-lookup-generator", &.{
        "tools/slang-lookup-generator/lookup-generator-main.cpp",
    }, &.{compiler_core_host}, &.{});
    const spirv_embed_exe = addHostExecutable(b, host_target, optimize, external, lua_include, "slang-spirv-embed-generator", &.{
        "tools/slang-spirv-embed-generator/spirv-embed-generator-main.cpp",
    }, &.{compiler_core_host}, &.{});
    const fiddle_exe = addHostExecutable(b, host_target, optimize, external, lua_include, "slang-fiddle",
        globSources(b, "tools/slang-fiddle", host_target), &.{compiler_core_host}, &.{});

    const generated = runGenerators(b, embed_exe, generate_exe, capability_exe, lookup_exe, spirv_embed_exe, fiddle_exe, external.spirv_headers);

    // The generated standard-module configuration header tells the compiler
    // where to look for optional standard modules at runtime.
    const standard_module_config = b.addWriteFiles();
    _ = standard_module_config.add("slang-standard-module-config.h", b.fmt(
        \\#ifndef SLANG_STANDARD_MODULE_CONFIG_H_INCLUDED
        \\#define SLANG_STANDARD_MODULE_CONFIG_H_INCLUDED
        \\#define SLANG_STANDARD_MODULE_DIR_NAME "slang-standard-module-{s}"
        \\#define SLANG_STANDARD_MODULE_INSTALL_DIR "lib/slang-standard-module-{s}"
        \\#define SLANG_NEURAL_MODULE_FILE_NAME "neural.slang-module"
        \\#define SLANG_WORKGRAPH_MODULE_FILE_NAME "workgraph.slang-module"
        \\#define SLANG_DISABLE_NOTE_IDS ""
        \\#endif
        \\
    , .{ default_slang_version, default_slang_version }));

    // Non-embedded compiler library, used only to build the bootstrap tool.
    const slang_base = addSlang(
        b,
        host_target,
        optimize,
        build_time_optimize,
        external,
        core_host,
        compiler_core_host,
        cmark_host,
        cmark_config.getDirectory(),
        generated,
        version_header.getDirectory(),
        standard_module_config.getDirectory(),
        "slang-compiler-base",
        null,
    );

    // Precompile the core module at build time, so creating a global session at
    // runtime never has to compile the standard library.
    const slang_bootstrap = addSlangBootstrap(
        b,
        host_target,
        optimize,
        external,
        slang_base,
        generated,
        cmark_config.getDirectory(),
        version_header.getDirectory(),
        standard_module_config.getDirectory(),
    );
    const bootstrap_run = b.addRunArtifact(slang_bootstrap);
    // The bootstrap tool prints progress ("Compiling core module ...") to stderr
    // (slang-global-session.cpp). This Run step has output args, so Zig captures
    // stderr and would treat that informational text as a diagnostic error.
    // Capture (and discard) it so Zig does not flag it.
    _ = bootstrap_run.captureStdErr();
    bootstrap_run.addArg("-compile-core-module");
    bootstrap_run.addArg("-archive-type");
    bootstrap_run.addArg("riff-lz4");
    bootstrap_run.addArg("-save-core-module");
    _ = bootstrap_run.addOutputFileArg("slang-core-module.bin");
    bootstrap_run.addArg("-save-core-module-bin-source");
    const core_module_header = bootstrap_run.addOutputFileArg("slang-core-module-generated.h");
    bootstrap_run.addArg("-save-glsl-module-bin-source");
    _ = bootstrap_run.addOutputFileArg("slang-glsl-module-generated.h");

    const slang = addSlang(
        b,
        target,
        optimize,
        optimize,
        external,
        core,
        compiler_core,
        cmark,
        cmark_config.getDirectory(),
        generated,
        version_header.getDirectory(),
        standard_module_config.getDirectory(),
        "slang-compiler",
        core_module_header.dirname(),
    );

    // The default `zig build` produces (and installs) the Slang compiler
    // library. There is deliberately no Zig-level API: integrators consume the
    // `slang-compiler` artifact and the public `include/` directory, then write
    // their own C++ shim or C bindings on top.
    b.installArtifact(slang);
    b.installArtifact(slang_glslang);
    b.installDirectory(.{
        .source_dir = b.path("include"),
        .install_dir = .header,
        .install_subdir = "",
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        version_header.getDirectory().path(b, "slang-tag-version.h"),
        .header,
        "slang-tag-version.h",
    ).step);

    // The build-time intermediate programs (generators and the bootstrap
    // compiler) are only executed during the build, but are also surfaced in
    // the install output so they can be inspected and run directly.
    for ([_]*std.Build.Step.Compile{
        embed_exe,
        generate_exe,
        capability_exe,
        lookup_exe,
        spirv_embed_exe,
        fiddle_exe,
        slang_bootstrap,
    }) |exe| b.installArtifact(exe);

    check.dependOn(&miniz.step);
    check.dependOn(&lz4.step);
    check.dependOn(&cmark.step);
    check.dependOn(&spirv_tools.step);
    check.dependOn(&glslang.step);
    check.dependOn(&slang_glslang.step);
    check.dependOn(&core.step);
    check.dependOn(&compiler_core.step);
    for (generated.steps) |step| check.dependOn(step);
    check.dependOn(&slang_base.step);
    check.dependOn(&bootstrap_run.step);
    check.dependOn(&slang.step);
}

/// Resolves every third-party source tree the build needs.
///
/// Upstream keeps these as git submodules under `external/`, which works for a
/// normal checkout but not for a Zig package fetched as a GitHub archive (an
/// archive cannot carry submodule contents). Each tree therefore resolves in
/// two stages: the checked-out `external/<name>` is preferred when it exists
/// (offline, no download), otherwise the Zig dependency of the same name
/// declared in `build.zig.zon` is used.
///
/// Every `lazyDependency` call is made before the first `null` is surfaced, so
/// one fetch round can satisfy all of the missing dependencies.
fn resolveExternal(b: *std.Build) ?External {
    const unordered_dense = externalRoot(b, "unordered_dense", "external/unordered_dense");
    const fast_float = externalRoot(b, "fast_float", "external/fast_float");
    const spirv_headers = externalRoot(b, "spirv_headers", "external/spirv-headers");
    const cmark = externalRoot(b, "cmark", "external/cmark");
    const miniz = externalRoot(b, "miniz", "external/miniz");
    const lz4 = externalRoot(b, "lz4", "external/lz4");
    const lua = externalRoot(b, "lua", "external/lua");
    const glslang = externalRoot(b, "glslang", "external/glslang");
    const spirv_tools = externalRoot(b, "spirv_tools", "external/spirv-tools");
    return .{
        .unordered_dense = unordered_dense orelse return null,
        .fast_float = fast_float orelse return null,
        .spirv_headers = spirv_headers orelse return null,
        .cmark = cmark orelse return null,
        .miniz = miniz orelse return null,
        .lz4 = lz4 orelse return null,
        .lua = lua orelse return null,
        .glslang = glslang orelse return null,
        .spirv_tools = spirv_tools orelse return null,
    };
}

/// Returns the root of one third-party tree: the checked-out submodule when
/// present, otherwise the corresponding (lazy) Zig dependency.
fn externalRoot(b: *std.Build, dep_name: []const u8, local_dir: []const u8) ?std.Build.LazyPath {
    if (isPopulatedDir(b, local_dir)) return b.path(local_dir);
    const dep = b.lazyDependency(dep_name, .{}) orelse return null;
    return dep.path(".");
}

/// True only when `rel` names a directory that actually has contents.
///
/// A git clone whose submodules were never initialized leaves the submodule
/// paths present but empty. Treating those as available would point the build at
/// missing sources (for example `external/spirv-tools/source`), so an empty
/// directory must fall through to the Zig dependency instead.
fn isPopulatedDir(b: *std.Build, rel: []const u8) bool {
    var d = std.fs.cwd().openDir(b.pathFromRoot(rel), .{ .iterate = true }) catch return false;
    defer d.close();
    var it = d.iterate();
    return (it.next() catch return false) != null;
}

/// Directory that satisfies `#include "lua/onelua.c"` in the slang-fiddle host
/// tool. When the lua submodule is checked out, `external/` already contains a
/// `lua/` entry. When lua comes from a Zig dependency, its package root has no
/// `lua/` path component, so the tree is copied into a generated directory
/// under a `lua/` subdirectory to preserve that include spelling.
fn luaIncludeDir(b: *std.Build, external: External) std.Build.LazyPath {
    if (isPopulatedDir(b, "external/lua")) return b.path("external");
    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(external.lua, "lua", .{});
    return wf.getDirectory();
}

const Generated = struct {
    /// Directory holding the generated `.fiddle` headers.
    fiddle_dir: std.Build.LazyPath,
    /// The step that produces the `.fiddle` files. Because those outputs are not
    /// individually declared, dependent compilations must depend on this step
    /// explicitly (the directory itself only depends on the placeholder writer).
    fiddle_step: *std.Build.Step,
    /// Directory holding the generated capability headers and lookup source.
    capability_dir: std.Build.LazyPath,
    /// Generated perfect-hash lookup source for `GLSL.std.450`.
    lookup_cpp: std.Build.LazyPath,
    /// Generated source embedding the SPIR-V core grammar JSON.
    spirv_core_cpp: std.Build.LazyPath,
    /// Directory holding the generated `*.meta.slang.h` headers.
    meta_dir: std.Build.LazyPath,
    /// Generated translation units for each `prelude/*-prelude.h`.
    prelude_cpps: []const std.Build.LazyPath,
    /// The run steps that produce the above, for explicit dependency wiring.
    steps: []const *std.Build.Step,
};

fn runGenerators(
    b: *std.Build,
    embed_exe: *std.Build.Step.Compile,
    generate_exe: *std.Build.Step.Compile,
    capability_exe: *std.Build.Step.Compile,
    lookup_exe: *std.Build.Step.Compile,
    spirv_embed_exe: *std.Build.Step.Compile,
    fiddle_exe: *std.Build.Step.Compile,
    spirv_headers_root: std.Build.LazyPath,
) Generated {
    const spirv_headers = spirv_headers_root.path(b, "include");

    var steps: std.ArrayList(*std.Build.Step) = .empty;

    // slang-fiddle: scrape C++ headers/templates into `.fiddle` files. The tool
    // concatenates its `-i`/`-o` prefixes directly with the input name and its
    // Lua scripts `require("source/slang/*.lua")` relative to the process working
    // directory, so run from the repository root and pass both prefixes with a
    // trailing separator (Zig only produces separator-suffixed directories via
    // `addDecoratedDirectoryArg`).
    const fiddle_out = b.addWriteFiles();
    _ = fiddle_out.add(".keep", "");
    const fiddle_dir = fiddle_out.getDirectory();
    const fiddle_run = b.addRunArtifact(fiddle_exe);
    fiddle_run.setCwd(b.path("."));
    fiddle_run.addArg("-i");
    fiddle_run.addDecoratedDirectoryArg("", b.path("source/slang"), "/");
    fiddle_run.addArg("-o");
    fiddle_run.addDecoratedDirectoryArg("", fiddle_dir, "/");
    for (listDirFiles(b, "source/slang", &.{ ".h", ".cpp" })) |name| {
        fiddle_run.addArg(name);
        fiddle_run.addFileInput(b.path(b.fmt("source/slang/{s}", .{name})));
    }
    // The templates `require()` sibling Lua modules; track them as inputs too
    // (without passing them on the command line).
    for (listDirFiles(b, "source/slang", &.{".lua"})) |name| {
        fiddle_run.addFileInput(b.path(b.fmt("source/slang/{s}", .{name})));
    }
    // A Run step that declares no output args is treated as having side effects
    // and therefore re-runs on every build. Adding an exit-code check switches
    // the step to the cacheable `.check` stdio mode, so it only re-runs when the
    // tracked inputs actually change (it still fails on a non-zero exit).
    fiddle_run.expectExitCode(0);
    steps.append(b.allocator, &fiddle_run.step) catch @panic("out of memory");

    // slang-capability-generator: `*.capdef` -> capability headers + lookup.
    const cap_run = b.addRunArtifact(capability_exe);
    cap_run.addFileArg(b.path("source/slang/slang-capabilities.capdef"));
    cap_run.addArg("--target-directory");
    const capability_dir = cap_run.addOutputDirectoryArg("capability");
    const doc = b.addWriteFiles();
    cap_run.addArg("--doc");
    cap_run.addFileArg(doc.add("capability-atoms.md", "\n"));
    steps.append(b.allocator, &cap_run.step) catch @panic("out of memory");

    // slang-lookup-generator: SPIR-V JSON grammar -> perfect-hash lookup.
    const lookup_run = b.addRunArtifact(lookup_exe);
    lookup_run.addFileArg(spirv_headers.path(b, "spirv/unified1/extinst.glsl.std.450.grammar.json"));
    const lookup_cpp = lookup_run.addOutputFileArg("slang-lookup-GLSLstd450.cpp");
    lookup_run.addArg("GLSLstd450");
    lookup_run.addArg("GLSLstd450");
    lookup_run.addArg("spirv/unified1/GLSL.std.450.h");
    steps.append(b.allocator, &lookup_run.step) catch @panic("out of memory");

    // slang-spirv-embed-generator: embed the SPIR-V core grammar JSON.
    const spirv_run = b.addRunArtifact(spirv_embed_exe);
    spirv_run.addFileArg(spirv_headers.path(b, "spirv/unified1/spirv.core.grammar.json"));
    const spirv_core_cpp = spirv_run.addOutputFileArg("slang-spirv-core-grammar-embed.cpp");
    steps.append(b.allocator, &spirv_run.step) catch @panic("out of memory");

    // slang-generate: `*.meta.slang` -> `*.meta.slang.h`.
    const meta_run = b.addRunArtifact(generate_exe);
    for (listDirFiles(b, "source/slang", &.{".meta.slang"})) |name| {
        meta_run.addFileArg(b.path(b.fmt("source/slang/{s}", .{name})));
    }
    meta_run.addArg("--target-directory");
    const meta_dir = meta_run.addOutputDirectoryArg("meta");
    steps.append(b.allocator, &meta_run.step) catch @panic("out of memory");

    // slang-embed: each prelude header -> a translation unit returning its text.
    var prelude_cpps: std.ArrayList(std.Build.LazyPath) = .empty;
    const prelude_headers = [_][]const u8{
        "slang-cpp-host-prelude.h",
        "slang-cpp-prelude.h",
        "slang-cuda-prelude.h",
        "slang-hlsl-prelude.h",
        "slang-torch-prelude.h",
    };
    for (prelude_headers) |name| {
        const run = b.addRunArtifact(embed_exe);
        run.addFileArg(b.path(b.fmt("prelude/{s}", .{name})));
        const out = run.addOutputFileArg(b.fmt("{s}.cpp", .{name}));
        run.addArg(b.fmt("-I{s}", .{b.pathFromRoot("source")}));
        run.addArg(b.fmt("-I{s}", .{b.pathFromRoot("include")}));
        run.addArg(b.fmt("-I{s}", .{b.pathFromRoot("prelude")}));
        prelude_cpps.append(b.allocator, out) catch @panic("out of memory");
        steps.append(b.allocator, &run.step) catch @panic("out of memory");
    }

    return .{
        .fiddle_dir = fiddle_dir,
        .fiddle_step = &fiddle_run.step,
        .capability_dir = capability_dir,
        .lookup_cpp = lookup_cpp,
        .spirv_core_cpp = spirv_core_cpp,
        .meta_dir = meta_dir,
        .prelude_cpps = prelude_cpps.toOwnedSlice(b.allocator) catch @panic("out of memory"),
        .steps = steps.toOwnedSlice(b.allocator) catch @panic("out of memory"),
    };
}

fn addSlang(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module_optimize: std.builtin.OptimizeMode,
    external: External,
    core: *std.Build.Step.Compile,
    compiler_core: *std.Build.Step.Compile,
    cmark: *std.Build.Step.Compile,
    cmark_config_dir: std.Build.LazyPath,
    generated: Generated,
    version_header_dir: std.Build.LazyPath,
    standard_module_config_dir: std.Build.LazyPath,
    name: []const u8,
    embedded_core_header_dir: ?std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = module_optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("source/slang"));
    mod.addIncludePath(b.path("tools"));
    mod.addIncludePath(b.path("external"));
    mod.addIncludePath(external.unordered_dense.path(b, "include"));
    mod.addIncludePath(external.fast_float.path(b, "include"));
    mod.addIncludePath(external.spirv_headers.path(b, "include"));
    mod.addIncludePath(cmark_config_dir);
    mod.addIncludePath(external.cmark.path(b, "src/include"));
    mod.addIncludePath(external.cmark.path(b, "extensions/include"));
    mod.addIncludePath(version_header_dir);
    mod.addIncludePath(standard_module_config_dir);
    mod.addIncludePath(generated.capability_dir);
    mod.addIncludePath(generated.fiddle_dir);
    mod.addIncludePath(generated.meta_dir);

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, slangDefines(b, target, optimize)) catch @panic("out of memory");
    // Record-replay is excluded from this build, matching SLANG_ENABLE_RECORD_REPLAY=OFF;
    // its C API is compiled as exported disabled stubs.
    flags.append(b.allocator, "-DSLANG_ENABLE_RECORD_REPLAY=0") catch @panic("out of memory");

    mod.addCSourceFiles(.{
        .files = globSources(b, "source/slang", target),
        .flags = flags.items,
    });
    mod.addCSourceFile(.{
        .file = b.path("source/slang-core-module/slang-embedded-core-module-source.cpp"),
        .flags = flags.items,
    });
    // `slang-embedded-core-module.cpp` either embeds the build-time precompiled
    // core module (when a generated header directory is provided) or stubs out
    // `slang_getEmbeddedCoreModule()`. The bootstrap library uses the stub; the
    // shipped library embeds the blob so no runtime compilation is needed.
    if (embedded_core_header_dir) |dir| {
        mod.addIncludePath(dir);
        var embed_flags: std.ArrayList([]const u8) = .empty;
        embed_flags.appendSlice(b.allocator, flags.items) catch @panic("out of memory");
        embed_flags.append(b.allocator, "-DSLANG_EMBED_CORE_MODULE=1") catch @panic("out of memory");
        mod.addCSourceFile(.{
            .file = b.path("source/slang-core-module/slang-embedded-core-module.cpp"),
            .flags = embed_flags.items,
        });
    } else {
        mod.addCSourceFile(.{
            .file = b.path("source/slang-core-module/slang-embedded-core-module.cpp"),
            .flags = flags.items,
        });
    }
    for (generated.prelude_cpps) |cpp| {
        mod.addCSourceFile(.{ .file = cpp, .flags = flags.items });
    }
    mod.addCSourceFile(.{
        .file = generated.capability_dir.path(b, "slang-lookup-capability-defs.cpp"),
        .flags = flags.items,
    });
    mod.addCSourceFile(.{ .file = generated.lookup_cpp, .flags = flags.items });
    mod.addCSourceFile(.{ .file = generated.spirv_core_cpp, .flags = flags.items });

    mod.linkLibrary(core);
    mod.linkLibrary(compiler_core);
    mod.linkLibrary(cmark);
    const lib = b.addLibrary(.{ .name = name, .linkage = .static, .root_module = mod });
    // `.fiddle` outputs are written into `fiddle_dir` by an undeclared-output
    // step, so the include path alone does not order this compilation after it.
    lib.step.dependOn(generated.fiddle_step);
    return lib;
}

/// Builds `slang-bootstrap`, a `slangc` variant (`-DSLANG_BOOTSTRAP=1`) linked
/// against the non-embedded compiler library. It is run at build time to
/// precompile the core module.
fn addSlangBootstrap(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    external: External,
    slang_lib: *std.Build.Step.Compile,
    generated: Generated,
    cmark_config_dir: std.Build.LazyPath,
    version_header_dir: std.Build.LazyPath,
    standard_module_config_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = build_time_optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("source/slang"));
    mod.addIncludePath(b.path("tools"));
    mod.addIncludePath(b.path("external"));
    mod.addIncludePath(external.unordered_dense.path(b, "include"));
    mod.addIncludePath(external.fast_float.path(b, "include"));
    mod.addIncludePath(external.spirv_headers.path(b, "include"));
    mod.addIncludePath(cmark_config_dir);
    mod.addIncludePath(external.cmark.path(b, "src/include"));
    mod.addIncludePath(external.cmark.path(b, "extensions/include"));
    mod.addIncludePath(version_header_dir);
    mod.addIncludePath(standard_module_config_dir);
    mod.addIncludePath(generated.capability_dir);
    mod.addIncludePath(generated.fiddle_dir);
    mod.addIncludePath(generated.meta_dir);
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, slangDefines(b, target, optimize)) catch @panic("out of memory");
    flags.append(b.allocator, "-DSLANG_BOOTSTRAP=1") catch @panic("out of memory");
    mod.addCSourceFile(.{
        .file = b.path("source/slangc/main.cpp"),
        .flags = flags.items,
    });
    mod.linkLibrary(slang_lib);
    return b.addExecutable(.{ .name = "slang-bootstrap", .root_module = mod, .linkage = hostLinkage(target) });
}

fn addHostExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    external: External,
    lua_include: std.Build.LazyPath,
    name: []const u8,
    sources: []const []const u8,
    libs: []const *std.Build.Step.Compile,
    extra_flags: []const []const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = build_time_optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("external"));
    mod.addIncludePath(external.unordered_dense.path(b, "include"));
    mod.addIncludePath(external.fast_float.path(b, "include"));
    mod.addIncludePath(external.spirv_headers.path(b, "include"));
    mod.addIncludePath(lua_include);
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, slangDefines(b, target, optimize)) catch @panic("out of memory");
    flags.appendSlice(b.allocator, extra_flags) catch @panic("out of memory");
    mod.addCSourceFiles(.{ .files = sources, .flags = flags.items });
    for (libs) |lib| mod.linkLibrary(lib);
    return b.addExecutable(.{ .name = name, .root_module = mod, .linkage = hostLinkage(target) });
}

/// Link mode for build-time host tools: static when they are built against musl
/// (see `hostTarget`), so the resulting executables have no ELF interpreter and
/// run regardless of the environment's dynamic linker. Otherwise keep the
/// consumer target's default linkage.
fn hostLinkage(target: std.Build.ResolvedTarget) ?std.builtin.LinkMode {
    return if (target.result.abi == .musl) .static else null;
}

/// Lists the names of files directly inside `dir` (non-recursive) matching any
/// of the provided extensions.
fn listDirFiles(b: *std.Build, dir: []const u8, exts: []const []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var d = b.build_root.handle.openDir(dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open directory '{s}': {s}", .{ dir, @errorName(err) });
    };
    defer d.close();
    var it = d.iterate();
    while (it.next() catch @panic("directory iteration failed")) |entry| {
        if (entry.kind != .file) continue;
        for (exts) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                list.append(b.allocator, b.dupe(entry.name)) catch @panic("out of memory");
                break;
            }
        }
    }
    return list.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

/// Common defines shared by every Slang C++ translation unit in a static build.
const slang_defines_base = [_][]const u8{
    "-std=c++20",
    "-DSLANG_STATIC=1",
    "-DSLANG_EMBED_CORE_MODULE_SOURCE=1",
    "-DSLANG_ENABLE_DXIL_SUPPORT=0",
    "-DSLANG_ENABLE_WEBGPU=0",
    "-DSLANG_ENABLE_VALIDATION_VM_BYTECODE=1",
    "-DSLANG_ENABLE_VALIDATION_FOSSIL=0",
    "-DSTB_IMAGE_STATIC=1",
    // `SLANG_ASSERT` lowers to `__builtin_assume` in non-debug builds, which
    // triggers this diagnostic; upstream disables it explicitly.
    "-Wno-assume",
    // Upstream's default warning set (cmake/CompilerFlags.cmake). The Zig-facing
    // Clang promotes several of these to errors, so silence them at the source.
    "-Wno-switch",
    "-Wno-parentheses",
    "-Wno-unused-local-typedefs",
    "-Wno-reorder",
    "-Wno-invalid-offsetof",
    "-Wno-newline-eof",
    "-Wno-return-std-move",
};

/// `_DEBUG` selects the aborting assertion path over `__builtin_assume`,
/// matching upstream's per-configuration define.
fn slangDefines(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, &slang_defines_base) catch @panic("out of memory");
    // musl gates the `fpos64_t` / `fgetpos64` aliases (used by
    // `FileStream::getPosition` on non-Windows, non-Apple platforms) behind
    // `_LARGEFILE64_SOURCE`; glibc exposes them unconditionally.
    if (target.result.abi == .musl)
        list.append(b.allocator, "-D_LARGEFILE64_SOURCE") catch @panic("out of memory");
    if (optimize == .Debug) list.append(b.allocator, "-D_DEBUG") catch @panic("out of memory");
    return list.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn addCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    external: External,
    miniz: *std.Build.Step.Compile,
    lz4: *std.Build.Step.Compile,
    miniz_export_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(external.unordered_dense.path(b, "include"));
    mod.addIncludePath(external.miniz);
    mod.addIncludePath(miniz_export_dir);
    mod.addIncludePath(external.lz4.path(b, "lib"));
    mod.addCSourceFiles(.{
        .files = globSources(b, "source/core", target),
        .flags = slangDefines(b, target, optimize),
    });
    mod.linkLibrary(miniz);
    mod.linkLibrary(lz4);
    return b.addLibrary(.{ .name = "core", .linkage = .static, .root_module = mod });
}

fn addCompilerCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    external: External,
    core: *std.Build.Step.Compile,
    version_header_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("external"));
    mod.addIncludePath(external.fast_float.path(b, "include"));
    mod.addIncludePath(external.spirv_headers.path(b, "include"));
    mod.addIncludePath(external.unordered_dense.path(b, "include"));
    mod.addIncludePath(version_header_dir);

    for (globSources(b, "source/compiler-core", target)) |file| {
        // The DXC headers require Microsoft extensions, and the flag conflicts
        // with precompiled headers upstream, so it is applied to this file only.
        if (std.mem.endsWith(u8, file, "slang-dxc-compiler.cpp")) {
            var flags: std.ArrayList([]const u8) = .empty;
            flags.appendSlice(b.allocator, slangDefines(b, target, optimize)) catch @panic("out of memory");
            flags.append(b.allocator, "-fms-extensions") catch @panic("out of memory");
            mod.addCSourceFile(.{ .file = b.path(file), .flags = flags.items });
        } else {
            mod.addCSourceFile(.{ .file = b.path(file), .flags = slangDefines(b, target, optimize) });
        }
    }
    mod.linkLibrary(core);
    return b.addLibrary(.{ .name = "compiler-core", .linkage = .static, .root_module = mod });
}

//
// Third-party libraries vendored under external/.
//

fn addMiniz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    miniz_root: std.Build.LazyPath,
    export_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(miniz_root);
    mod.addIncludePath(export_dir);
    const flags = &.{ "-std=gnu99", "-DMINIZ_STATIC_DEFINE" };
    for ([_][]const u8{
        "miniz.c",
        "miniz_zip.c",
        "miniz_tinfl.c",
        "miniz_tdef.c",
    }) |name| {
        mod.addCSourceFile(.{ .file = miniz_root.path(b, name), .flags = flags });
    }
    return b.addLibrary(.{ .name = "miniz", .linkage = .static, .root_module = mod });
}

fn addLz4(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lz4_root: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const lib = lz4_root.path(b, "lib");
    mod.addIncludePath(lib);
    const flags = &.{ "-std=gnu99", "-DXXH_NAMESPACE=LZ4_" };
    for ([_][]const u8{
        "lz4.c",
        "lz4file.c",
        "lz4frame.c",
        "lz4hc.c",
        "xxhash.c",
    }) |name| {
        mod.addCSourceFile(.{ .file = lib.path(b, name), .flags = flags });
    }
    return b.addLibrary(.{ .name = "lz4", .linkage = .static, .root_module = mod });
}

fn addCmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cmark_root: std.Build.LazyPath,
    config_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(config_dir);
    mod.addIncludePath(cmark_root.path(b, "src/include"));
    mod.addIncludePath(cmark_root.path(b, "extensions/include"));
    mod.addCMacro("CMARK_USE_CMAKE_HEADERS", "1");
    mod.addCMacro("CMARK_GFM_STATIC_DEFINE", "1");
    const src = cmark_root.path(b, "src");
    const flags = &.{"-std=c99"};
    for ([_][]const u8{
        "arena.c",
        "blocks.c",
        "buffer.c",
        "cmark.c",
        "cmark_ctype.c",
        "commonmark.c",
        "footnotes.c",
        "houdini_href_e.c",
        "houdini_html_e.c",
        "houdini_html_u.c",
        "html.c",
        "inlines.c",
        "iterator.c",
        "latex.c",
        "linked_list.c",
        "man.c",
        "map.c",
        "node.c",
        "plaintext.c",
        "plugin.c",
        "references.c",
        "registry.c",
        "render.c",
        "scanners.c",
        "syntax_extension.c",
        "utf8.c",
        "xml.c",
    }) |name| {
        mod.addCSourceFile(.{ .file = src.path(b, name), .flags = flags });
    }
    return b.addLibrary(.{ .name = "cmark-gfm", .linkage = .static, .root_module = mod });
}

//
// Source globbing (mirrors cmake/Glob.cmake's slang_glob_sources).
//

fn globSources(b: *std.Build, dir: []const u8, target: std.Build.ResolvedTarget) []const []const u8 {
    const os = target.result.os.tag;
    var list: std.ArrayList([]const u8) = .empty;
    var d = b.build_root.handle.openDir(dir, .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open source directory '{s}': {s}", .{ dir, @errorName(err) });
    };
    defer d.close();
    var walker = d.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    while (walker.next() catch @panic("source walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".cpp")) continue;
        if (sourceExcluded(entry.path, os)) continue;
        list.append(b.allocator, b.pathJoin(&.{ dir, entry.path })) catch @panic("out of memory");
    }
    return list.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn sourceExcluded(path: []const u8, os: std.Target.Os.Tag) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |comp| {
        if (comp.len == 0) continue;
        if (os != .windows) {
            if (std.mem.eql(u8, comp, "windows")) return true;
            if (std.mem.startsWith(u8, comp, "d3d")) return true;
            if (std.mem.eql(u8, comp, "open-gl")) return true;
        }
        if (os != .macos and std.mem.eql(u8, comp, "metal")) return true;
        if (os != .windows and os != .linux and os != .macos and std.mem.eql(u8, comp, "vulkan")) return true;
        if (!isUnix(os) and std.mem.eql(u8, comp, "unix")) return true;
    }
    return false;
}

fn isUnix(os: std.Target.Os.Tag) bool {
    return switch (os) {
        .linux, .macos, .freebsd, .netbsd, .openbsd, .dragonfly, .solaris, .illumos, .haiku, .serenity, .ios, .tvos, .watchos, .visionos, .driverkit => true,
        else => false,
    };
}

/// Recursively collects the `.cpp` files under `root`, skipping any whose
/// relative path contains one of `excludes`, and returns them as lazy paths so
/// the caller can add them from either a checked-out `external/` directory or a
/// Zig dependency (which lives outside the build root).
fn globCpp(b: *std.Build, root: std.Build.LazyPath, excludes: []const []const u8) []std.Build.LazyPath {
    var list: std.ArrayList(std.Build.LazyPath) = .empty;
    const abs = root.getPath(b);
    var d = std.fs.cwd().openDir(abs, .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open source directory '{s}': {s}", .{ abs, @errorName(err) });
    };
    defer d.close();
    var walker = d.walk(b.allocator) catch @panic("out of memory");
    defer walker.deinit();
    while (walker.next() catch @panic("source walk failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".cpp")) continue;
        var excluded = false;
        for (excludes) |ex| {
            if (std.mem.indexOf(u8, entry.path, ex) != null) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        list.append(b.allocator, root.path(b, entry.path)) catch @panic("out of memory");
    }
    return list.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

//
// glslang + SPIRV-Tools, used by the in-process `slang-glslang` module that
// provides spirv-opt / spirv-val / spirv-link. The grammar tables and glslang's
// `build_info.h` are the pre-generated copies checked into the repository
// (external/spirv-tools-generated, external/glslang-generated), so no Python or
// bison is required at build time.
//

fn addSpirvTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    spirv_tools_root: std.Build.LazyPath,
    generated_root: std.Build.LazyPath,
    spirv_headers_root: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    mod.addIncludePath(spirv_tools_root);
    mod.addIncludePath(spirv_tools_root.path(b, "include"));
    mod.addIncludePath(generated_root);
    mod.addIncludePath(spirv_headers_root.path(b, "include"));
    const flags = &.{ "-std=c++17", "-w" };
    for (globCpp(b, spirv_tools_root.path(b, "source"), &.{
        "fuzz/",
        "wasm/",
        "pch",
        "mimalloc.cpp",
        "util/timer.cpp",
    })) |file| {
        mod.addCSourceFile(.{ .file = file, .flags = flags });
    }
    return b.addLibrary(.{ .name = "SPIRV-Tools", .linkage = .static, .root_module = mod });
}

fn addGlslang(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glslang_root: std.Build.LazyPath,
    glslang_generated_root: std.Build.LazyPath,
    spirv_tools_root: std.Build.LazyPath,
    spirv_tools_generated_root: std.Build.LazyPath,
    spirv_headers_root: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    mod.addIncludePath(glslang_root);
    mod.addIncludePath(glslang_generated_root);
    mod.addIncludePath(spirv_tools_root.path(b, "include"));
    mod.addIncludePath(spirv_tools_generated_root);
    mod.addIncludePath(spirv_headers_root.path(b, "include"));
    mod.addCMacro("ENABLE_HLSL", "1");
    mod.addCMacro("ENABLE_OPT", "1");

    const flags = &.{ "-std=c++17", "-w" };
    const os_exclude: []const []const u8 = if (target.result.os.tag == .windows)
        &.{ "OSDependent/Unix/", "OSDependent/Web/" }
    else
        &.{ "OSDependent/Windows/", "OSDependent/Web/" };
    var os_excludes: std.ArrayList([]const u8) = .empty;
    os_excludes.appendSlice(b.allocator, &.{"stub.cpp"}) catch @panic("out of memory");
    os_excludes.appendSlice(b.allocator, os_exclude) catch @panic("out of memory");
    for (globCpp(b, glslang_root.path(b, "glslang"), os_excludes.items)) |file| {
        mod.addCSourceFile(.{ .file = file, .flags = flags });
    }
    for (globCpp(b, glslang_root.path(b, "SPIRV"), &.{})) |file| {
        mod.addCSourceFile(.{ .file = file, .flags = flags });
    }
    return b.addLibrary(.{ .name = "glslang", .linkage = .static, .root_module = mod });
}

fn addSlangGlslang(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glslang: *std.Build.Step.Compile,
    spirv_tools: *std.Build.Step.Compile,
    external: External,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("source/slang-glslang"));
    mod.addIncludePath(external.glslang);
    mod.addIncludePath(external.spirv_tools.path(b, "include"));
    mod.addIncludePath(external.spirv_headers.path(b, "include"));
    mod.addCSourceFiles(.{
        .files = &.{
            "source/slang-glslang/slang-glslang.cpp",
            "source/slang-glslang/slang-glslang-embedded.cpp",
        },
        .flags = &.{ "-std=c++17", "-w", "-DSLANG_STATIC=1" },
    });
    mod.linkLibrary(glslang);
    mod.linkLibrary(spirv_tools);
    // A static library, not a dlopen'd module: it is linked into the consumer's
    // executable together with `slang-compiler`, so there is a single C++ runtime
    // and nothing to load or unload at run time.
    return b.addLibrary(.{
        .name = "slang-glslang",
        .linkage = .static,
        .root_module = mod,
    });
}
