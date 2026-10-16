const std = @import("std");

/// Version baked into the generated `slang-tag-version.h`. The upstream build
/// derives this from git tags; there are none in a plain checkout, so we pin a
/// fallback and allow overriding through `-Dslang-version=...`.
const default_slang_version = "0.0.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check = b.step("check", "Compile intermediate libraries without linking the final artifact");

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

    const miniz = addMiniz(b, target, optimize, miniz_export.getDirectory());

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

    const lz4 = addLz4(b, target, optimize);
    const cmark = addCmark(b, target, optimize, cmark_config.getDirectory());

    // glslang + SPIRV-Tools and the `slang-glslang` module they back.
    const spirv_tools = addSpirvTools(b, target, optimize);
    const glslang = addGlslang(b, target, optimize);
    const slang_glslang = addSlangGlslang(b, target, optimize, glslang, spirv_tools);

    const version_header = b.addWriteFiles();
    _ = version_header.add("slang-tag-version.h", b.fmt(
        \\#define SLANG_TAG_VERSION "{s}"
        \\#define SLANG_VERSION_NUMERIC "{s}"
        \\
    , .{ default_slang_version, default_slang_version }));

    const core = addCore(b, target, optimize, miniz, lz4, miniz_export.getDirectory());
    const compiler_core = addCompilerCore(b, target, optimize, core, version_header.getDirectory());

    // Host tools compiled from the repository itself (the "generators").
    const embed_exe = addHostExecutable(b, target, optimize, "slang-embed", &.{
        "tools/slang-embed/slang-embed.cpp",
    }, &.{core}, &.{});
    const generate_exe = addHostExecutable(b, target, optimize, "slang-generate", &.{
        "tools/slang-generate/main.cpp",
    }, &.{core}, &.{});
    const capability_exe = addHostExecutable(b, target, optimize, "slang-capability-generator", &.{
        "tools/slang-capability-generator/capability-generator-main.cpp",
    }, &.{compiler_core}, &.{});
    const lookup_exe = addHostExecutable(b, target, optimize, "slang-lookup-generator", &.{
        "tools/slang-lookup-generator/lookup-generator-main.cpp",
    }, &.{compiler_core}, &.{});
    const spirv_embed_exe = addHostExecutable(b, target, optimize, "slang-spirv-embed-generator", &.{
        "tools/slang-spirv-embed-generator/spirv-embed-generator-main.cpp",
    }, &.{compiler_core}, &.{});
    const fiddle_exe = addHostExecutable(b, target, optimize, "slang-fiddle",
        globSources(b, "tools/slang-fiddle", target), &.{compiler_core}, &.{});

    const generated = runGenerators(b, embed_exe, generate_exe, capability_exe, lookup_exe, spirv_embed_exe, fiddle_exe);

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
        target,
        optimize,
        core,
        compiler_core,
        cmark,
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
        target,
        optimize,
        slang_base,
        generated,
        cmark_config.getDirectory(),
        version_header.getDirectory(),
        standard_module_config.getDirectory(),
    );
    const bootstrap_run = b.addRunArtifact(slang_bootstrap);
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
) Generated {
    const spirv_headers = b.path("external/spirv-headers/include");

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
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("source/slang"));
    mod.addIncludePath(b.path("tools"));
    mod.addIncludePath(b.path("external"));
    mod.addIncludePath(b.path("external/unordered_dense/include"));
    mod.addIncludePath(b.path("external/fast_float/include"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
    mod.addIncludePath(cmark_config_dir);
    mod.addIncludePath(b.path("external/cmark/src/include"));
    mod.addIncludePath(b.path("external/cmark/extensions/include"));
    mod.addIncludePath(version_header_dir);
    mod.addIncludePath(standard_module_config_dir);
    mod.addIncludePath(generated.capability_dir);
    mod.addIncludePath(generated.fiddle_dir);
    mod.addIncludePath(generated.meta_dir);

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, slangDefines(b, optimize)) catch @panic("out of memory");
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
    slang_lib: *std.Build.Step.Compile,
    generated: Generated,
    cmark_config_dir: std.Build.LazyPath,
    version_header_dir: std.Build.LazyPath,
    standard_module_config_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    mod.addIncludePath(b.path("source"));
    mod.addIncludePath(b.path("include"));
    mod.addIncludePath(b.path("source/slang"));
    mod.addIncludePath(b.path("tools"));
    mod.addIncludePath(b.path("external"));
    mod.addIncludePath(b.path("external/unordered_dense/include"));
    mod.addIncludePath(b.path("external/fast_float/include"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
    mod.addIncludePath(cmark_config_dir);
    mod.addIncludePath(b.path("external/cmark/src/include"));
    mod.addIncludePath(b.path("external/cmark/extensions/include"));
    mod.addIncludePath(version_header_dir);
    mod.addIncludePath(standard_module_config_dir);
    mod.addIncludePath(generated.capability_dir);
    mod.addIncludePath(generated.fiddle_dir);
    mod.addIncludePath(generated.meta_dir);
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, slangDefines(b, optimize)) catch @panic("out of memory");
    flags.append(b.allocator, "-DSLANG_BOOTSTRAP=1") catch @panic("out of memory");
    mod.addCSourceFile(.{
        .file = b.path("source/slangc/main.cpp"),
        .flags = flags.items,
    });
    mod.linkLibrary(slang_lib);
    return b.addExecutable(.{ .name = "slang-bootstrap", .root_module = mod });
}

fn addHostExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    sources: []const []const u8,
    libs: []const *std.Build.Step.Compile,
    extra_flags: []const []const u8,
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
    mod.addIncludePath(b.path("external/unordered_dense/include"));
    mod.addIncludePath(b.path("external/fast_float/include"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, slangDefines(b, optimize)) catch @panic("out of memory");
    flags.appendSlice(b.allocator, extra_flags) catch @panic("out of memory");
    mod.addCSourceFiles(.{ .files = sources, .flags = flags.items });
    for (libs) |lib| mod.linkLibrary(lib);
    return b.addExecutable(.{ .name = name, .root_module = mod });
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
fn slangDefines(b: *std.Build, optimize: std.builtin.OptimizeMode) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    list.appendSlice(b.allocator, &slang_defines_base) catch @panic("out of memory");
    if (optimize == .Debug) list.append(b.allocator, "-D_DEBUG") catch @panic("out of memory");
    return list.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn addCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    mod.addIncludePath(b.path("external/unordered_dense/include"));
    mod.addIncludePath(b.path("external/miniz"));
    mod.addIncludePath(miniz_export_dir);
    mod.addIncludePath(b.path("external/lz4/lib"));
    mod.addCSourceFiles(.{
        .files = globSources(b, "source/core", target),
        .flags = slangDefines(b, optimize),
    });
    mod.linkLibrary(miniz);
    mod.linkLibrary(lz4);
    return b.addLibrary(.{ .name = "core", .linkage = .static, .root_module = mod });
}

fn addCompilerCore(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
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
    mod.addIncludePath(b.path("external/fast_float/include"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
    mod.addIncludePath(b.path("external/unordered_dense/include"));
    mod.addIncludePath(version_header_dir);

    for (globSources(b, "source/compiler-core", target)) |file| {
        // The DXC headers require Microsoft extensions, and the flag conflicts
        // with precompiled headers upstream, so it is applied to this file only.
        if (std.mem.endsWith(u8, file, "slang-dxc-compiler.cpp")) {
            var flags: std.ArrayList([]const u8) = .empty;
            flags.appendSlice(b.allocator, slangDefines(b, optimize)) catch @panic("out of memory");
            flags.append(b.allocator, "-fms-extensions") catch @panic("out of memory");
            mod.addCSourceFile(.{ .file = b.path(file), .flags = flags.items });
        } else {
            mod.addCSourceFile(.{ .file = b.path(file), .flags = slangDefines(b, optimize) });
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
    export_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("external/miniz"));
    mod.addIncludePath(export_dir);
    mod.addCSourceFiles(.{
        .files = &.{
            "external/miniz/miniz.c",
            "external/miniz/miniz_zip.c",
            "external/miniz/miniz_tinfl.c",
            "external/miniz/miniz_tdef.c",
        },
        .flags = &.{ "-std=gnu99", "-DMINIZ_STATIC_DEFINE" },
    });
    return b.addLibrary(.{ .name = "miniz", .linkage = .static, .root_module = mod });
}

fn addLz4(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path("external/lz4/lib"));
    mod.addCSourceFiles(.{
        .files = &.{
            "external/lz4/lib/lz4.c",
            "external/lz4/lib/lz4file.c",
            "external/lz4/lib/lz4frame.c",
            "external/lz4/lib/lz4hc.c",
            "external/lz4/lib/xxhash.c",
        },
        .flags = &.{ "-std=gnu99", "-DXXH_NAMESPACE=LZ4_" },
    });
    return b.addLibrary(.{ .name = "lz4", .linkage = .static, .root_module = mod });
}

fn addCmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    config_dir: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(config_dir);
    mod.addIncludePath(b.path("external/cmark/src/include"));
    mod.addIncludePath(b.path("external/cmark/extensions/include"));
    mod.addCMacro("CMARK_USE_CMAKE_HEADERS", "1");
    mod.addCMacro("CMARK_GFM_STATIC_DEFINE", "1");
    mod.addCSourceFiles(.{
        .files = &.{
            "external/cmark/src/arena.c",
            "external/cmark/src/blocks.c",
            "external/cmark/src/buffer.c",
            "external/cmark/src/cmark.c",
            "external/cmark/src/cmark_ctype.c",
            "external/cmark/src/commonmark.c",
            "external/cmark/src/footnotes.c",
            "external/cmark/src/houdini_href_e.c",
            "external/cmark/src/houdini_html_e.c",
            "external/cmark/src/houdini_html_u.c",
            "external/cmark/src/html.c",
            "external/cmark/src/inlines.c",
            "external/cmark/src/iterator.c",
            "external/cmark/src/latex.c",
            "external/cmark/src/linked_list.c",
            "external/cmark/src/man.c",
            "external/cmark/src/map.c",
            "external/cmark/src/node.c",
            "external/cmark/src/plaintext.c",
            "external/cmark/src/plugin.c",
            "external/cmark/src/references.c",
            "external/cmark/src/registry.c",
            "external/cmark/src/render.c",
            "external/cmark/src/scanners.c",
            "external/cmark/src/syntax_extension.c",
            "external/cmark/src/utf8.c",
            "external/cmark/src/xml.c",
        },
        .flags = &.{"-std=c99"},
    });
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

/// Recursively collects `.cpp` files under `dir`, skipping any whose path
/// contains one of `excludes`.
fn globCpp(b: *std.Build, dir: []const u8, excludes: []const []const u8) []const []const u8 {
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
        var excluded = false;
        for (excludes) |ex| {
            if (std.mem.indexOf(u8, entry.path, ex) != null) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        list.append(b.allocator, b.pathJoin(&.{ dir, entry.path })) catch @panic("out of memory");
    }
    return list.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

//
// glslang + SPIRV-Tools, used by the dlopen'd `slang-glslang` module that
// provides spirv-opt / spirv-val / spirv-link. The grammar tables and glslang's
// `build_info.h` are the pre-generated copies checked into the repository
// (external/spirv-tools-generated, external/glslang-generated), so no Python or
// bison is required at build time.
//

fn addSpirvTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    mod.addIncludePath(b.path("external/spirv-tools"));
    mod.addIncludePath(b.path("external/spirv-tools/include"));
    mod.addIncludePath(b.path("external/spirv-tools-generated"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
    mod.addCSourceFiles(.{
        .files = globCpp(b, "external/spirv-tools/source", &.{
            "fuzz/",
            "wasm/",
            "pch",
            "mimalloc.cpp",
            "util/timer.cpp",
        }),
        .flags = &.{ "-std=c++17", "-w" },
    });
    return b.addLibrary(.{ .name = "SPIRV-Tools", .linkage = .static, .root_module = mod });
}

fn addGlslang(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
    });
    mod.addIncludePath(b.path("external/glslang"));
    mod.addIncludePath(b.path("external/glslang-generated"));
    mod.addIncludePath(b.path("external/spirv-tools/include"));
    mod.addIncludePath(b.path("external/spirv-tools-generated"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
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
    mod.addCSourceFiles(.{
        .files = globCpp(b, "external/glslang/glslang", os_excludes.items),
        .flags = flags,
    });
    mod.addCSourceFiles(.{
        .files = globCpp(b, "external/glslang/SPIRV", &.{}),
        .flags = flags,
    });
    return b.addLibrary(.{ .name = "glslang", .linkage = .static, .root_module = mod });
}

fn addSlangGlslang(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glslang: *std.Build.Step.Compile,
    spirv_tools: *std.Build.Step.Compile,
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
    mod.addIncludePath(b.path("external/glslang"));
    mod.addIncludePath(b.path("external/spirv-tools/include"));
    mod.addIncludePath(b.path("external/spirv-headers/include"));
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
