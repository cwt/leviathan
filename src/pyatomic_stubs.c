// Stub implementations of CPython atomic functions for free-threading builds.
// Zig's @cImport doesn't properly inline static inline functions from CPython headers,
// so we provide these stubs that use GCC builtins directly.

#include <stdint.h>

// These are the atomic functions that CPython's free-threading headers reference
// but don't export from libpython. We provide implementations using GCC/Clang builtins.

uint64_t _Py_atomic_load_uint64_relaxed(const uint64_t *obj) {
    return __atomic_load_n(obj, __ATOMIC_RELAXED);
}

uint32_t _Py_atomic_load_uint32_relaxed(const uint32_t *obj) {
    return __atomic_load_n(obj, __ATOMIC_RELAXED);
}
