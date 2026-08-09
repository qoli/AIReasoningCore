/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "AIReasoningiSHTestSupport.h"
#include "AIReasoningiSHRuntime.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct fixture_session {
    bool exited;
    bool stdin_closed;
    int32_t exit_code;
} fixture_session_t;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static size_t byte_counts[256];
static size_t written_count;
static int32_t signals[16];
static size_t signal_count;
static fixture_session_t *active_session;

static int fixture_boot(const ish_embed_boot_opts_t *opts, ish_embed_instance_t **instance) {
    if (opts == NULL || instance == NULL) return ISH_ERR_INVALID_ARG;
    *instance = (ish_embed_instance_t *)(uintptr_t)1;
    return ISH_OK;
}

static int fixture_spawn(ish_embed_instance_t *instance, const ish_embed_spawn_opts_t *opts, ish_embed_session_t **session) {
    if (instance == NULL || opts == NULL || session == NULL) return ISH_ERR_INVALID_ARG;
    fixture_session_t *created = calloc(1, sizeof(*created));
    if (created == NULL) return ISH_ERR_OOM;
    pthread_mutex_lock(&lock);
    memset(byte_counts, 0, sizeof(byte_counts));
    written_count = 0;
    signal_count = 0;
    active_session = created;
    pthread_mutex_unlock(&lock);
    *session = (ish_embed_session_t *)created;
    return ISH_OK;
}

static int fixture_read(ish_embed_session_t *session, uint32_t wait_ms, uint8_t **buffer, size_t *length, int *kind, uint64_t *sequence, int32_t *exit_code, int32_t *signal_number) {
    fixture_session_t *fixture = (fixture_session_t *)session;
    pthread_mutex_lock(&lock);
    if (!fixture->exited) {
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_nsec += (long)(wait_ms % 1000) * 1000000L;
        deadline.tv_sec += wait_ms / 1000 + deadline.tv_nsec / 1000000000L;
        deadline.tv_nsec %= 1000000000L;
        pthread_cond_timedwait(&condition, &lock, &deadline);
    }
    if (!fixture->exited) {
        pthread_mutex_unlock(&lock);
        return ISH_ERR_TIMEOUT;
    }
    *buffer = NULL;
    *length = 0;
    *kind = 3;
    *sequence = 1;
    *exit_code = fixture->exit_code;
    *signal_number = 0;
    pthread_mutex_unlock(&lock);
    return ISH_OK;
}

static int fixture_write(ish_embed_session_t *session, const uint8_t *buffer, size_t length) {
    fixture_session_t *fixture = (fixture_session_t *)session;
    pthread_mutex_lock(&lock);
    if (fixture->stdin_closed) {
        pthread_mutex_unlock(&lock);
        return ISH_ERR_BROKEN_PIPE;
    }
    for (size_t index = 0; index < length; index += 1) byte_counts[buffer[index]] += 1;
    written_count += length;
    pthread_mutex_unlock(&lock);
    return ISH_OK;
}

static int fixture_close_stdin(ish_embed_session_t *session) {
    fixture_session_t *fixture = (fixture_session_t *)session;
    pthread_mutex_lock(&lock);
    int status = fixture->stdin_closed ? ISH_ERR_BROKEN_PIPE : ISH_OK;
    fixture->stdin_closed = true;
    pthread_mutex_unlock(&lock);
    return status;
}

static int fixture_signal(ish_embed_session_t *session, int signal_number) {
    (void)session;
    pthread_mutex_lock(&lock);
    if (signal_count < 16) signals[signal_count++] = signal_number;
    pthread_mutex_unlock(&lock);
    return ISH_OK;
}

static int fixture_terminate(ish_embed_session_t *session, uint32_t grace_ms) {
    (void)grace_ms;
    fixture_signal(session, 15);
    fixture_signal(session, 9);
    return ISH_OK;
}

static void fixture_close_session(ish_embed_session_t *session) {
    pthread_mutex_lock(&lock);
    if (active_session == (fixture_session_t *)session) active_session = NULL;
    pthread_mutex_unlock(&lock);
    free(session);
}

static int fixture_shutdown(ish_embed_instance_t *instance, uint32_t grace_ms) {
    (void)instance;
    (void)grace_ms;
    return ISH_OK;
}

static void fixture_free(void *buffer) { free(buffer); }
static const char *fixture_error(int status) { (void)status; return "fixture error"; }

bool ARISHFixtureInstall(void) {
    static const ARISHHostRuntimeV1 runtime = {
        .abi_version = ARISH_HOST_RUNTIME_ABI_VERSION,
        .structure_size = sizeof(ARISHHostRuntimeV1),
        .boot = fixture_boot,
        .spawn = fixture_spawn,
        .read = fixture_read,
        .write = fixture_write,
        .close_stdin = fixture_close_stdin,
        .signal = fixture_signal,
        .terminate = fixture_terminate,
        .close_session = fixture_close_session,
        .shutdown = fixture_shutdown,
        .free_buffer = fixture_free,
        .error_string = fixture_error,
    };
    return ARISHRegisterHostRuntimeV1(&runtime);
}

void ARISHFixtureReset(void) {
    pthread_mutex_lock(&lock);
    memset(byte_counts, 0, sizeof(byte_counts));
    written_count = 0;
    signal_count = 0;
    pthread_mutex_unlock(&lock);
}

void ARISHFixtureComplete(int32_t exit_code) {
    pthread_mutex_lock(&lock);
    if (active_session != NULL) {
        active_session->exit_code = exit_code;
        active_session->exited = true;
        pthread_cond_broadcast(&condition);
    }
    pthread_mutex_unlock(&lock);
}

size_t ARISHFixtureWrittenByteCount(void) {
    pthread_mutex_lock(&lock);
    size_t count = written_count;
    pthread_mutex_unlock(&lock);
    return count;
}

size_t ARISHFixtureCountOfByte(uint8_t byte) {
    pthread_mutex_lock(&lock);
    size_t count = byte_counts[byte];
    pthread_mutex_unlock(&lock);
    return count;
}

size_t ARISHFixtureSignalCount(void) {
    pthread_mutex_lock(&lock);
    size_t count = signal_count;
    pthread_mutex_unlock(&lock);
    return count;
}

int32_t ARISHFixtureSignalAtIndex(size_t index) {
    pthread_mutex_lock(&lock);
    int32_t value = index < signal_count ? signals[index] : -1;
    pthread_mutex_unlock(&lock);
    return value;
}
