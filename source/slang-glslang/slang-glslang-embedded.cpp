// slang-glslang-embedded.cpp
//
// In-process provider for the `slang-glslang` downstream compiler.
//
// Upstream ships `slang-glslang` as a dlopen'd module. Because this port links
// its C++ runtime statically into every artifact, loading such a module would
// put two C++ runtimes in one process, and unloading it crashes at exit. This
// file instead exposes the module's `glslang_*` entry points (compiled into the
// same library) through a custom ISlangSharedLibraryLoader, so Slang uses them
// in-process and no shared library is ever loaded or unloaded.

#include "slang.h"
#include "slang-com-helper.h"

#include "slang-glslang.h"

#include <atomic>
#include <cstring>

// The `extern "C"` entry points defined by slang-glslang.cpp, compiled into the
// same library. Their C signatures match the typedefs in slang-glslang.h.
extern "C"
{
    int glslang_compile(glslang_CompileRequest_1_0* request);
    int glslang_compile_1_1(glslang_CompileRequest_1_1* request);
    int glslang_compile_1_2(glslang_CompileRequest_1_2* request);
    int glslang_compile_1_3(glslang_CompileRequest_1_3* request);
    bool glslang_validateSPIRV(const uint32_t* contents, int contentsSize);
    bool glslang_disassembleSPIRV(const uint32_t* contents, int contentsSize);
    bool glslang_disassembleSPIRVWithResult(
        const uint32_t* contents,
        int contentsSize,
        char** outString);
    void glslang_freeDisassembly(char* disassembly);
    int glslang_linkSPIRV(glslang_LinkRequest* request);
}

namespace
{

/// An ISlangSharedLibrary backed by the in-process `glslang_*` functions.
class EmbeddedGlslangLibrary : public ISlangSharedLibrary
{
public:
    SLANG_NO_THROW SlangResult SLANG_MCALL
    queryInterface(const SlangUUID& uuid, void** outObject) SLANG_OVERRIDE
    {
        if (!outObject)
            return SLANG_E_INVALID_ARG;
        void* intf = castAs(uuid);
        *outObject = intf;
        if (intf)
        {
            addRef();
            return SLANG_OK;
        }
        return SLANG_E_NO_INTERFACE;
    }

    SLANG_NO_THROW uint32_t SLANG_MCALL addRef() SLANG_OVERRIDE { return ++m_refCount; }

    SLANG_NO_THROW uint32_t SLANG_MCALL release() SLANG_OVERRIDE
    {
        uint32_t count = --m_refCount;
        if (count == 0)
            delete this;
        return count;
    }

    SLANG_NO_THROW void* SLANG_MCALL castAs(const SlangUUID& guid) SLANG_OVERRIDE
    {
        if (guid == ISlangUnknown::getTypeGuid() || guid == ISlangCastable::getTypeGuid() ||
            guid == ISlangSharedLibrary::getTypeGuid())
        {
            return static_cast<ISlangSharedLibrary*>(this);
        }
        return nullptr;
    }

    SLANG_NO_THROW void* SLANG_MCALL findSymbolAddressByName(char const* name) SLANG_OVERRIDE
    {
        if (std::strcmp(name, "glslang_compile") == 0)
            return reinterpret_cast<void*>(&glslang_compile);
        if (std::strcmp(name, "glslang_compile_1_1") == 0)
            return reinterpret_cast<void*>(&glslang_compile_1_1);
        if (std::strcmp(name, "glslang_compile_1_2") == 0)
            return reinterpret_cast<void*>(&glslang_compile_1_2);
        if (std::strcmp(name, "glslang_compile_1_3") == 0)
            return reinterpret_cast<void*>(&glslang_compile_1_3);
        if (std::strcmp(name, "glslang_validateSPIRV") == 0)
            return reinterpret_cast<void*>(&glslang_validateSPIRV);
        if (std::strcmp(name, "glslang_disassembleSPIRV") == 0)
            return reinterpret_cast<void*>(&glslang_disassembleSPIRV);
        if (std::strcmp(name, "glslang_disassembleSPIRVWithResult") == 0)
            return reinterpret_cast<void*>(&glslang_disassembleSPIRVWithResult);
        if (std::strcmp(name, "glslang_freeDisassembly") == 0)
            return reinterpret_cast<void*>(&glslang_freeDisassembly);
        if (std::strcmp(name, "glslang_linkSPIRV") == 0)
            return reinterpret_cast<void*>(&glslang_linkSPIRV);
        return nullptr;
    }

private:
    std::atomic<uint32_t> m_refCount{0};
};

/// A loader that serves the `slang-glslang` name from the in-process library and
/// reports everything else as unavailable (the other downstream compilers are
/// not built in this port).
class EmbeddedGlslangLoader : public ISlangSharedLibraryLoader
{
public:
    SLANG_NO_THROW SlangResult SLANG_MCALL
    queryInterface(const SlangUUID& uuid, void** outObject) SLANG_OVERRIDE
    {
        if (!outObject)
            return SLANG_E_INVALID_ARG;
        if (uuid == ISlangUnknown::getTypeGuid() ||
            uuid == ISlangSharedLibraryLoader::getTypeGuid())
        {
            *outObject = static_cast<ISlangSharedLibraryLoader*>(this);
            addRef();
            return SLANG_OK;
        }
        *outObject = nullptr;
        return SLANG_E_NO_INTERFACE;
    }

    SLANG_NO_THROW uint32_t SLANG_MCALL addRef() SLANG_OVERRIDE { return ++m_refCount; }

    SLANG_NO_THROW uint32_t SLANG_MCALL release() SLANG_OVERRIDE { return --m_refCount; }

    SLANG_NO_THROW SlangResult SLANG_MCALL
    loadSharedLibrary(const char* path, ISlangSharedLibrary** outSharedLibrary) SLANG_OVERRIDE
    {
        if (!outSharedLibrary)
            return SLANG_E_INVALID_ARG;
        *outSharedLibrary = nullptr;
        if (path && std::strstr(path, "slang-glslang") != nullptr)
        {
            auto* library = new EmbeddedGlslangLibrary();
            library->addRef();
            *outSharedLibrary = library;
            return SLANG_OK;
        }
        return SLANG_E_NOT_FOUND;
    }

private:
    std::atomic<uint32_t> m_refCount{0};
};

} // namespace

extern "C" void slang_glslang_install_embedded(void* globalSession)
{
    if (!globalSession)
        return;
    // Process-lifetime singleton; intentionally never destroyed.
    static EmbeddedGlslangLoader* loader = [] {
        auto* l = new EmbeddedGlslangLoader();
        l->addRef();
        return l;
    }();
    static_cast<slang::IGlobalSession*>(globalSession)->setSharedLibraryLoader(loader);
}
