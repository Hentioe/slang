# Slang（Zig 构建 / Zig 依赖）

本项目把 [shader-slang/slang](https://github.com/shader-slang/slang) 打包成一个可由其它
Zig 项目直接依赖的构建过程与编译产物。

**目的**：让其它 Zig 项目把 Slang 当作一个普通的 Zig 依赖引入（通过 `build.zig.zon`），
**无需把 Slang 源码复制进自己的工程**。本依赖负责：

- 把 Slang 编译成静态库：`libslang-compiler.a`、`libslang-glslang.a`；
- 提供 Slang 的公共头文件目录；
- 提供一个用于装载进程内下游编译器的 C 函数。

集成方只需链接这两个静态库并 `addIncludePath`，然后自行编写 C++ shim 或
`@cImport`/`extern` 接入使用。**本依赖不提供任何 Zig 层 API。**

> [!WARNING]
> **注意**：本项目主要是给 [Hentioe/jve](https://github.com/Hentioe/jve) 提供支持，除此之外的作用都不会成为首要目的。

## 外部集成

本项目**不提供任何 Zig 层的 API**。它只提供构建产物（`slang-compiler`、`slang-glslang`
两个静态库）与公共头文件目录，以及一个用于装载进程内下游编译器的 C 函数。集成方拿到后
自行编写 C++ shim 或 `@cImport`/`extern` 去接入。

下面是完整的集成步骤。把本项目作为普通 Zig 依赖引入即可，无需把 Slang 源码复制进项目。

### 1. 在 `build.zig.zon` 添加依赖

```sh
zig fetch --save git+https://github.com/Hentioe/slang
```

### 2. 在 `build.zig` 中接入

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const slang_dep = b.dependency("slang", .{
        .target = target,
        .optimize = optimize,
        // 可选：构建期中间程序（生成器、slang-bootstrap）是否用 musl 静态编译。
        // 默认 false（跟随目标 libc）；沙箱环境缺动态加载器时再打开。
        // .host_musl_static = true,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Slang 底层是 C++ 静态库，必须链接 libc++。
        .link_libc = true,
        .link_libcpp = true,
    });

    // 关键：include 路径不会随 addImport 传递，必须显式添加。
    exe_mod.addIncludePath(slang_dep.path("include"));
    // 链接 Slang 静态库（产物名固定为 slang-compiler）。
    exe_mod.linkLibrary(slang_dep.artifact("slang-compiler"));
    // 链接进程内的 downstream 编译器（glslang + SPIRV-Tools；spirv-opt 等）。
    exe_mod.linkLibrary(slang_dep.artifact("slang-glslang"));

    const exe = b.addExecutable(.{ .name = "my_project", .root_module = exe_mod });
    b.installArtifact(exe);
}
```

### 3. 自行接入 Slang

`include/slang.h` 是**纯 C++ 头**（无条件使用 `namespace`/`class`/`enum class`），
`@cImport` 无法直接翻译。集成方有两条路：

- **自写 C++ shim**：在自己的构建里用 `addCSourceFile` 编译一个 `.cpp`，其中
  `#include <slang.h>`（可配合 `include/slang-com-ptr.h` 的 `Slang::ComPtr`），
  对外暴露 `extern "C"` 接口，再由 Zig 调用。编译该文件需
  `-std=c++20 -DSLANG_STATIC=1`，并确保模块 `link_libcpp = true`。
- **扁平 C API**：库导出的 `sp*` / `slang_*` 系列本身就是 `extern "C"` 符号，
  集成方可以自行手写一个最小 C 头并 `@cImport`，或直接 `extern "C" fn` 声明。

### 4. 初始化：装载进程内下游编译器（必需）

Slang 的下游编译器（`spirv-opt` 等）是**运行时经 `ISlangSharedLibraryLoader` 按需加载**的，
默认走 `DefaultSharedLibraryLoader`（即 `dlopen`）。所以**只把静态库链接进来不会生效**，
必须在取得全局会话之后、创建 session / 编译之前，调用一次本库导出的装载函数：

```cpp
// 本库导出（见 source/slang-glslang/slang-glslang-embedded.h）；参数是 slang::IGlobalSession*。
extern "C" void slang_glslang_install_embedded(void* globalSession);

// 正确的调用位置与顺序：
slang::IGlobalSession* global = nullptr;
slang_createGlobalSession(SLANG_API_VERSION, &global);

slang_glslang_install_embedded(global); // 必须，且要在这里（建 session / 编译之前）

// 之后再 slang::IGlobalSession::createSession(...) / 编译。
```

它内部执行 `global->setSharedLibraryLoader(<进程内 loader>)`，使下游能力从进程内实现获取，
无需任何 `.so`、rpath 或 `LD_LIBRARY_PATH`。

**漏掉此调用的症状**（因为 Slang 仍用默认加载器去 `dlopen`）：

```plaintext
error[E00100]: failed to load downstream compiler 'spirv-opt'
note[E99996]: failed to load dynamic library 'slang-glslang-0.0.0'
```

## 说明与注意事项

- **构建工具由集成方负责，而非本依赖**。本依赖自身通过 Zig 自带的 C++ 工具链
  （`zig c++`，含 libc++）编译全部 C++ 源码，不要求集成方安装 CMake、g++ 或
  clang。集成方只需：
  - 一个满足 `minimum_zig_version` 的 Zig。
  - 首次构建需要能访问网络：Slang 的第三方源码（glslang、SPIRV-Tools、cmark、
    miniz、lz4、lua、unordered_dense、fast_float、SPIRV-Headers）已在本依赖的
    `build.zig.zon` 中声明为 git 依赖（仓库 URL + commit），Zig 会自动拉取并缓存。**无需手动 `git
    submodule update`**（本地检出中若已初始化对应子模块，则直接复用、不联网）。
  - 若集成方目标平台（如交叉编译、其它 ABI）缺少合适的工具链，那属于集成方自
    行解决的问题，本依赖不为此负责。
- 集成包含**两处代码/构建改动**：`linkLibrary(slang-glslang)`（步骤 2），以及创建
  全局会话后调用 `slang_glslang_install_embedded(global)`（步骤 4）。缺任一，下游
  编译器都会走 `dlopen` 并报 `E00100`/`E99996`。
- 首次构建需要从头编译整个 Slang 静态库，耗时与内存开销较大；这与上游 CMake
  构建一致，且无 PCH 加速。构建期还会运行一次 `slang-bootstrap` 预编译 core
  module（打印 `Compiling core module ...`，约数十秒），但这只发生在构建期。
- **构建期工具固定以 `ReleaseFast` 构建，不跟随集成方的 `optimize`**：这些步骤
  只在构建期运行、产物是生成数据或预编译的 core module，不进最终运行库，外部选
  Debug 时对它们没有意义（反而拖慢构建）。固定为 fast 的步骤有：
  `slang-embed`、`slang-generate`、`slang-capability-generator`、
  `slang-lookup-generator`、`slang-spirv-embed-generator`、`slang-fiddle`、
  `slang-bootstrap`、`slang-compiler-base`。
  出厂产物（`libslang-compiler.a`、`libslang-glslang.a`）及它们链接的
  `core`、`compiler-core`、`cmark-gfm`、`miniz`、`lz4`、`glslang`、
  `SPIRV-Tools` 仍然跟随集成方的 `optimize`。
- **构建期中间程序默认使用目标 libc**。若在缺少目标动态加载器的沙箱环境（如
  NixOS）中构建、导致这些工具无法执行（`FileNotFound`/ENOENT），可在依赖参数里传
  `.host_musl_static = true`，让它们改为 musl 静态链接；直接构建本仓库时等价于
  `zig build -Dhost_musl_static=true`（默认 `false`，即默认 libc）。
- **需要把静态库链接进共享库时启用 PIC**。默认构建不会显式要求目标侧静态库以
  位置无关代码编译；若集成方要把 `libslang-compiler.a` / `libslang-glslang.a`
  再链接进自己的 `.so`，需要传 `.pic = true`（直接构建时等价于
  `zig build -Dpic=true`）。该选项只影响目标侧库，构建期 host 工具保持原样。
  它本身不产出 `.so`，共享库仍由集成方创建。
