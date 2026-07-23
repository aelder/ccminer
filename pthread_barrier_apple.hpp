/*
 * Minimal pthread barrier for macOS, which does not provide
 * pthread_barrier_t.
 */

#ifndef PTHREAD_BARRIER_APPLE_HPP
#define PTHREAD_BARRIER_APPLE_HPP

#include <errno.h>
#include <pthread.h>

typedef int pthread_barrierattr_t;

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    unsigned int arrived;
    unsigned int required;
    unsigned int generation;
} pthread_barrier_t;

static inline int pthread_barrier_init(
    pthread_barrier_t *barrier,
    const pthread_barrierattr_t *,
    unsigned int count)
{
    if (count == 0) {
        errno = EINVAL;
        return -1;
    }
    if (pthread_mutex_init(&barrier->mutex, nullptr) != 0)
        return -1;
    if (pthread_cond_init(&barrier->condition, nullptr) != 0) {
        pthread_mutex_destroy(&barrier->mutex);
        return -1;
    }
    barrier->arrived = 0;
    barrier->required = count;
    barrier->generation = 0;
    return 0;
}

static inline int pthread_barrier_destroy(pthread_barrier_t *barrier)
{
    pthread_cond_destroy(&barrier->condition);
    pthread_mutex_destroy(&barrier->mutex);
    return 0;
}

static inline int pthread_barrier_wait(pthread_barrier_t *barrier)
{
    pthread_mutex_lock(&barrier->mutex);
    const unsigned int generation = barrier->generation;
    if (++barrier->arrived == barrier->required) {
        barrier->arrived = 0;
        ++barrier->generation;
        pthread_cond_broadcast(&barrier->condition);
        pthread_mutex_unlock(&barrier->mutex);
        return 1;
    }
    while (generation == barrier->generation)
        pthread_cond_wait(&barrier->condition, &barrier->mutex);
    pthread_mutex_unlock(&barrier->mutex);
    return 0;
}

#endif
