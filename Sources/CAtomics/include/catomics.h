#ifndef CATOMICS_H
#define CATOMICS_H

#include <stdint.h>

// Minimal acquire/release atomics for the SPSC ring buffer.
// Swift (macOS 13 deployment target) has no built-in atomics; this shim
// wraps the compiler builtins so no external package is needed.

#ifdef __cplusplus
extern "C" {
#endif

uint64_t catomic_load_relaxed(const uint64_t *p);
uint64_t catomic_load_acquire(const uint64_t *p);
void     catomic_store_relaxed(uint64_t *p, uint64_t v);
void     catomic_store_release(uint64_t *p, uint64_t v);

#ifdef __cplusplus
}
#endif

#endif /* CATOMICS_H */
