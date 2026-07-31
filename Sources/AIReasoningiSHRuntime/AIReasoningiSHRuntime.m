#import "AIReasoningiSHRuntime.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static Class executor_class(void) {
    return NSClassFromString(@"ISHShellExecutor");
}

static SEL start_selector(void) {
    return NSSelectorFromString(
        @"startExecutable:arguments:environment:lineCallback:completion:"
    );
}

bool ARISHExecutorClassIsLinked(void) {
    return executor_class() != Nil;
}

bool ARISHExecutorIsAvailable(void) {
    Class cls = executor_class();
    return cls != Nil
        && [cls respondsToSelector:start_selector()]
        && [cls respondsToSelector:NSSelectorFromString(@"writeStandardInput:forProcess:")]
        && [cls respondsToSelector:NSSelectorFromString(@"closeStandardInputForProcess:")]
        && [cls respondsToSelector:NSSelectorFromString(@"killProcessGroup:withSignal:")];
}

int32_t ARISHStart(
    const char *executable,
    const uint8_t *arguments_json,
    size_t arguments_json_length,
    const uint8_t *environment_json,
    size_t environment_json_length,
    ARISHLineCallback line_callback,
    ARISHCompletionCallback completion_callback,
    void *context
) {
    if (!ARISHExecutorIsAvailable() || executable == NULL) {
        return -1;
    }

    NSError *error = nil;
    NSData *argumentsData = [NSData dataWithBytes:arguments_json
                                           length:arguments_json_length];
    NSArray<NSString *> *arguments =
        [NSJSONSerialization JSONObjectWithData:argumentsData options:0 error:&error];
    if (error != nil || ![arguments isKindOfClass:[NSArray class]]) {
        return -2;
    }

    NSData *environmentData = [NSData dataWithBytes:environment_json
                                             length:environment_json_length];
    NSDictionary<NSString *, NSString *> *environment =
        [NSJSONSerialization JSONObjectWithData:environmentData options:0 error:&error];
    if (error != nil || ![environment isKindOfClass:[NSDictionary class]]) {
        return -2;
    }

    void (^lineBlock)(NSString *, BOOL) = ^(NSString *line, BOOL isStdErr) {
        if (line_callback != NULL) {
            line_callback(line.UTF8String, isStdErr, context);
        }
    };
    void (^completionBlock)(id) = ^(id result) {
        if (completion_callback == NULL) {
            return;
        }
        int32_t pid = [[result valueForKey:@"pid"] intValue];
        int32_t exitCode = [[result valueForKey:@"exitCode"] intValue];
        int32_t executionError = [[result valueForKey:@"error"] intValue];
        NSString *standardError = [result valueForKey:@"errorOutput"] ?: @"";
        completion_callback(
            pid,
            exitCode,
            executionError,
            standardError.UTF8String,
            context
        );
    };

    typedef int32_t (*StartFunction)(
        id,
        SEL,
        NSString *,
        NSArray<NSString *> *,
        NSDictionary<NSString *, NSString *> *,
        void (^)(NSString *, BOOL),
        void (^)(id)
    );
    StartFunction start = (StartFunction)objc_msgSend;
    return start(
        executor_class(),
        start_selector(),
        [NSString stringWithUTF8String:executable],
        arguments,
        environment,
        lineBlock,
        completionBlock
    );
}

bool ARISHWriteStandardInput(
    int32_t pid,
    const uint8_t *bytes,
    size_t length
) {
    if (!ARISHExecutorIsAvailable() || (bytes == NULL && length != 0)) {
        return false;
    }
    NSData *data = [NSData dataWithBytes:bytes length:length];
    typedef BOOL (*WriteFunction)(id, SEL, NSData *, int32_t);
    WriteFunction write = (WriteFunction)objc_msgSend;
    return write(
        executor_class(),
        NSSelectorFromString(@"writeStandardInput:forProcess:"),
        data,
        pid
    );
}

bool ARISHCloseStandardInput(int32_t pid) {
    if (!ARISHExecutorIsAvailable()) {
        return false;
    }
    typedef BOOL (*CloseFunction)(id, SEL, int32_t);
    CloseFunction closeInput = (CloseFunction)objc_msgSend;
    return closeInput(
        executor_class(),
        NSSelectorFromString(@"closeStandardInputForProcess:"),
        pid
    );
}

bool ARISHKillProcessGroup(int32_t pid, int32_t signal_number) {
    if (!ARISHExecutorIsAvailable()) {
        return false;
    }
    typedef BOOL (*KillFunction)(id, SEL, int32_t, int32_t);
    KillFunction killGroup = (KillFunction)objc_msgSend;
    return killGroup(
        executor_class(),
        NSSelectorFromString(@"killProcessGroup:withSignal:"),
        pid,
        signal_number
    );
}
