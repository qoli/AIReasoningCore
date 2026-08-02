// SPDX-License-Identifier: GPL-3.0-or-later

#include "AIReasoningiSHRuntime.h"

const ARISHHostRuntimeV1 *ARISHOpenMinisHostRuntimeV1(void) {
    static const ARISHHostRuntimeV1 runtime = {
        .abi_version = ARISH_HOST_RUNTIME_ABI_VERSION,
        .structure_size = sizeof(ARISHHostRuntimeV1),
        .boot = ish_embed_boot,
        .spawn = ish_embed_spawn,
        .read = ish_embed_session_read,
        .write = ish_embed_session_write,
        .close_stdin = ish_embed_session_close_stdin,
        .signal = ish_embed_session_signal,
        .terminate = ish_embed_session_terminate,
        .close_session = ish_embed_session_close,
        .shutdown = ish_embed_shutdown,
        .free_buffer = ish_embed_free,
        .error_string = ish_embed_strerror,
    };
    return &runtime;
}
