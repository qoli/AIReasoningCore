/* SPDX-License-Identifier: GPL-3.0-or-later */

#include "AIReasoningiSHRuntime.h"

#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

static pthread_mutex_t runtime_lock = PTHREAD_MUTEX_INITIALIZER;
static ARISHHostRuntimeV1 registered_runtime;
static bool runtime_registered = false;

static bool runtime_is_complete(const ARISHHostRuntimeV1 *runtime) {
    return runtime != NULL
        && runtime->abi_version == ARISH_HOST_RUNTIME_ABI_VERSION
        && runtime->structure_size == sizeof(ARISHHostRuntimeV1)
        && runtime->boot != NULL
        && runtime->spawn != NULL
        && runtime->read != NULL
        && runtime->write != NULL
        && runtime->close_stdin != NULL
        && runtime->signal != NULL
        && runtime->terminate != NULL
        && runtime->close_session != NULL
        && runtime->shutdown != NULL
        && runtime->free_buffer != NULL
        && runtime->error_string != NULL;
}

bool ARISHRegisterHostRuntimeV1(const ARISHHostRuntimeV1 *runtime) {
    if (!runtime_is_complete(runtime)) {
        return false;
    }
    pthread_mutex_lock(&runtime_lock);
    if (runtime_registered) {
        pthread_mutex_unlock(&runtime_lock);
        return false;
    }
    memcpy(&registered_runtime, runtime, sizeof(registered_runtime));
    runtime_registered = true;
    pthread_mutex_unlock(&runtime_lock);
    return true;
}

bool ARISHRegisterLinkedOpenMinisHostRuntime(void) {
    typedef const ARISHHostRuntimeV1 *(*provider_fn)(void);
    provider_fn provider = (provider_fn)dlsym(
        RTLD_DEFAULT,
        "ARISHOpenMinisHostRuntimeV1"
    );
    if (provider == NULL) {
        return false;
    }
    return ARISHRegisterHostRuntimeV1(provider());
}

bool ARISHHostRuntimeIsRegistered(void) {
    pthread_mutex_lock(&runtime_lock);
    bool registered = runtime_registered;
    pthread_mutex_unlock(&runtime_lock);
    return registered;
}

static bool snapshot(ARISHHostRuntimeV1 *runtime) {
    pthread_mutex_lock(&runtime_lock);
    bool registered = runtime_registered;
    if (registered) {
        memcpy(runtime, &registered_runtime, sizeof(*runtime));
    }
    pthread_mutex_unlock(&runtime_lock);
    return registered;
}

#define WITH_RUNTIME_OR_RETURN(name, expression) \
    ARISHHostRuntimeV1 name;                     \
    if (!snapshot(&name)) {                      \
        return ARISH_RUNTIME_ERR_NOT_REGISTERED; \
    }                                            \
    return (expression)

int ARISHRuntimeBoot(const ish_embed_boot_opts_t *opts, ish_embed_instance_t **instance) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.boot(opts, instance));
}

int ARISHRuntimeSpawn(ish_embed_instance_t *instance, const ish_embed_spawn_opts_t *opts, ish_embed_session_t **session) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.spawn(instance, opts, session));
}

int ARISHRuntimeRead(ish_embed_session_t *session, uint32_t wait_ms, uint8_t **buffer, size_t *length, int *kind, uint64_t *sequence, int32_t *exit_code, int32_t *signal_number) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.read(session, wait_ms, buffer, length, kind, sequence, exit_code, signal_number));
}

int ARISHRuntimeWrite(ish_embed_session_t *session, const uint8_t *buffer, size_t length) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.write(session, buffer, length));
}

int ARISHRuntimeCloseStandardInput(ish_embed_session_t *session) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.close_stdin(session));
}

int ARISHRuntimeSignal(ish_embed_session_t *session, int signal_number) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.signal(session, signal_number));
}

int ARISHRuntimeTerminate(ish_embed_session_t *session, uint32_t grace_ms) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.terminate(session, grace_ms));
}

void ARISHRuntimeCloseSession(ish_embed_session_t *session) {
    ARISHHostRuntimeV1 runtime;
    if (snapshot(&runtime)) {
        runtime.close_session(session);
    }
}

int ARISHRuntimeShutdown(ish_embed_instance_t *instance, uint32_t grace_ms) {
    WITH_RUNTIME_OR_RETURN(runtime, runtime.shutdown(instance, grace_ms));
}

void ARISHRuntimeFree(void *buffer) {
    ARISHHostRuntimeV1 runtime;
    if (snapshot(&runtime)) {
        runtime.free_buffer(buffer);
    }
}

const char *ARISHRuntimeErrorString(int status) {
    if (status == ARISH_RUNTIME_ERR_NOT_REGISTERED) {
        return "AIReasoningiSH host runtime is not registered";
    }
    if (status == ARISH_RUNTIME_ERR_INVALID_TABLE) {
        return "AIReasoningiSH host runtime table is invalid";
    }
    ARISHHostRuntimeV1 runtime;
    if (!snapshot(&runtime)) {
        return "AIReasoningiSH host runtime is not registered";
    }
    return runtime.error_string(status);
}
