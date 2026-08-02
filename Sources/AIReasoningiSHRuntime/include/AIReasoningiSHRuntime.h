#ifndef AIReasoningiSHRuntime_h
#define AIReasoningiSHRuntime_h

#include "AIReasoningiSHHostABI.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ARISH_HOST_RUNTIME_ABI_VERSION 1u
#define ARISH_RUNTIME_ERR_NOT_REGISTERED (-1000)
#define ARISH_RUNTIME_ERR_INVALID_TABLE  (-1001)

typedef struct ARISHHostRuntimeV1 {
    uint32_t abi_version;
    size_t structure_size;
    int (*boot)(const ish_embed_boot_opts_t *, ish_embed_instance_t **);
    int (*spawn)(ish_embed_instance_t *, const ish_embed_spawn_opts_t *, ish_embed_session_t **);
    int (*read)(ish_embed_session_t *, uint32_t, uint8_t **, size_t *, int *, uint64_t *, int32_t *, int32_t *);
    int (*write)(ish_embed_session_t *, const uint8_t *, size_t);
    int (*close_stdin)(ish_embed_session_t *);
    int (*signal)(ish_embed_session_t *, int);
    int (*terminate)(ish_embed_session_t *, uint32_t);
    void (*close_session)(ish_embed_session_t *);
    int (*shutdown)(ish_embed_instance_t *, uint32_t);
    void (*free_buffer)(void *);
    const char *(*error_string)(int);
} ARISHHostRuntimeV1;

bool ARISHRegisterHostRuntimeV1(const ARISHHostRuntimeV1 *runtime);
/* Explicitly discovers the opt-in host provider linked by the application.
 * This never loads a framework or substitutes another executor. */
bool ARISHRegisterLinkedOpenMinisHostRuntime(void);
bool ARISHHostRuntimeIsRegistered(void);

int ARISHRuntimeBoot(const ish_embed_boot_opts_t *opts, ish_embed_instance_t **instance);
int ARISHRuntimeSpawn(ish_embed_instance_t *instance, const ish_embed_spawn_opts_t *opts, ish_embed_session_t **session);
int ARISHRuntimeRead(ish_embed_session_t *session, uint32_t wait_ms, uint8_t **buffer, size_t *length, int *kind, uint64_t *sequence, int32_t *exit_code, int32_t *signal_number);
int ARISHRuntimeWrite(ish_embed_session_t *session, const uint8_t *buffer, size_t length);
int ARISHRuntimeCloseStandardInput(ish_embed_session_t *session);
int ARISHRuntimeSignal(ish_embed_session_t *session, int signal_number);
int ARISHRuntimeTerminate(ish_embed_session_t *session, uint32_t grace_ms);
void ARISHRuntimeCloseSession(ish_embed_session_t *session);
int ARISHRuntimeShutdown(ish_embed_instance_t *instance, uint32_t grace_ms);
void ARISHRuntimeFree(void *buffer);
const char *ARISHRuntimeErrorString(int status);

#ifdef __cplusplus
}
#endif

#endif
