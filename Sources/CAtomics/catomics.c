#include "catomics.h"

uint64_t catomic_load_relaxed(const uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_RELAXED);
}

uint64_t catomic_load_acquire(const uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

void catomic_store_relaxed(uint64_t *p, uint64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELAXED);
}

void catomic_store_release(uint64_t *p, uint64_t v) {
    __atomic_store_n(p, v, __ATOMIC_RELEASE);
}
