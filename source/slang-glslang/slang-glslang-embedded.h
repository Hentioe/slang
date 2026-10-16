// slang-glslang-embedded.h
//
// In-process replacement for the dlopen'd `slang-glslang` module. Call
// `slang_glslang_install_embedded` on a global session to have Slang use the
// statically linked glslang/SPIRV-Tools entry points instead of loading a
// separate shared library. This keeps the process to a single C++ runtime.

#ifndef SLANG_GLSLANG_EMBEDDED_H
#define SLANG_GLSLANG_EMBEDDED_H

#ifdef __cplusplus
extern "C"
{
#endif

    /// Install an in-process `slang-glslang` provider on the given global
    /// session (`void*` is a `slang::IGlobalSession*`). Must be called before
    /// any session/compilation that needs SPIR-V optimization is created.
    void slang_glslang_install_embedded(void* globalSession);

#ifdef __cplusplus
}
#endif

#endif
