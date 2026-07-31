#ifndef AIReasoningiSHRuntime_h
#define AIReasoningiSHRuntime_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef void (*ARISHLineCallback)(
    const char *line,
    bool is_standard_error,
    void *context
);

typedef void (*ARISHCompletionCallback)(
    int32_t pid,
    int32_t exit_code,
    int32_t execution_error,
    const char *standard_error,
    void *context
);

bool ARISHExecutorClassIsLinked(void);
bool ARISHExecutorIsAvailable(void);

int32_t ARISHStart(
    const char *executable,
    const uint8_t *arguments_json,
    size_t arguments_json_length,
    const uint8_t *environment_json,
    size_t environment_json_length,
    ARISHLineCallback line_callback,
    ARISHCompletionCallback completion_callback,
    void *context
);

bool ARISHWriteStandardInput(
    int32_t pid,
    const uint8_t *bytes,
    size_t length
);

bool ARISHCloseStandardInput(int32_t pid);
bool ARISHKillProcessGroup(int32_t pid, int32_t signal_number);

#endif
