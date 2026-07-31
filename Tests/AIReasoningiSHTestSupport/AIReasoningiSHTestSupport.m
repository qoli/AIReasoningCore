#import "AIReasoningiSHTestSupport.h"

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

typedef void (^FixtureLineCallback)(NSString *, BOOL);
typedef void (^FixtureCompletionCallback)(id);

@interface ARISHFixtureResult : NSObject
@property(nonatomic) int32_t pid;
@property(nonatomic) int32_t exitCode;
@property(nonatomic) int32_t error;
@property(nonatomic, copy) NSString *errorOutput;
@end

@implementation ARISHFixtureResult
@end

static NSLock *fixtureLock;
static NSMutableData *fixtureData;
static NSMutableArray<NSNumber *> *fixtureSignals;
static FixtureCompletionCallback fixtureCompletion;
static int32_t fixturePID;
static BOOL fixtureClosed;

static int32_t fixture_start(
    id self,
    SEL selector,
    NSString *executable,
    NSArray<NSString *> *arguments,
    NSDictionary<NSString *, NSString *> *environment,
    FixtureLineCallback lineCallback,
    FixtureCompletionCallback completion
) {
    [fixtureLock lock];
    fixturePID += 1;
    fixtureData = [NSMutableData data];
    fixtureSignals = [NSMutableArray array];
    fixtureCompletion = [completion copy];
    fixtureClosed = NO;
    int32_t pid = fixturePID;
    [fixtureLock unlock];
    return pid;
}

static BOOL fixture_write(
    id self,
    SEL selector,
    NSData *data,
    int32_t pid
) {
    [fixtureLock lock];
    BOOL valid = pid == fixturePID && !fixtureClosed;
    if (valid) {
        [fixtureData appendData:data];
    }
    [fixtureLock unlock];
    return valid;
}

static BOOL fixture_close(id self, SEL selector, int32_t pid) {
    [fixtureLock lock];
    BOOL valid = pid == fixturePID && !fixtureClosed;
    if (valid) {
        fixtureClosed = YES;
    }
    [fixtureLock unlock];
    return valid;
}

static BOOL fixture_kill(
    id self,
    SEL selector,
    int32_t pid,
    int32_t signal
) {
    [fixtureLock lock];
    BOOL valid = pid == fixturePID;
    if (valid) {
        [fixtureSignals addObject:@(signal)];
    }
    [fixtureLock unlock];
    return valid;
}

bool ARISHFixtureInstall(void) {
    if (NSClassFromString(@"ISHShellExecutor") != Nil) {
        return false;
    }
    fixtureLock = [[NSLock alloc] init];
    fixtureData = [NSMutableData data];
    fixtureSignals = [NSMutableArray array];
    fixturePID = 40;

    Class cls = objc_allocateClassPair(
        [NSObject class],
        "ISHShellExecutor",
        0
    );
    if (cls == Nil) {
        return false;
    }
    Class metaclass = object_getClass(cls);
    class_addMethod(
        metaclass,
        NSSelectorFromString(
            @"startExecutable:arguments:environment:lineCallback:completion:"
        ),
        (IMP)fixture_start,
        "i@:@@@@@"
    );
    class_addMethod(
        metaclass,
        NSSelectorFromString(@"writeStandardInput:forProcess:"),
        (IMP)fixture_write,
        "B@:@i"
    );
    class_addMethod(
        metaclass,
        NSSelectorFromString(@"closeStandardInputForProcess:"),
        (IMP)fixture_close,
        "B@:i"
    );
    class_addMethod(
        metaclass,
        NSSelectorFromString(@"killProcessGroup:withSignal:"),
        (IMP)fixture_kill,
        "B@:ii"
    );
    objc_registerClassPair(cls);
    return true;
}

void ARISHFixtureReset(void) {
    [fixtureLock lock];
    fixtureData = [NSMutableData data];
    fixtureSignals = [NSMutableArray array];
    fixtureCompletion = nil;
    fixtureClosed = NO;
    [fixtureLock unlock];
}

void ARISHFixtureComplete(int32_t exit_code) {
    [fixtureLock lock];
    FixtureCompletionCallback completion = fixtureCompletion;
    fixtureCompletion = nil;
    ARISHFixtureResult *result = [[ARISHFixtureResult alloc] init];
    result.pid = fixturePID;
    result.exitCode = exit_code;
    result.error = 0;
    result.errorOutput = @"";
    [fixtureLock unlock];
    if (completion != nil) {
        completion(result);
    }
}

size_t ARISHFixtureWrittenByteCount(void) {
    [fixtureLock lock];
    size_t count = fixtureData.length;
    [fixtureLock unlock];
    return count;
}

size_t ARISHFixtureCountOfByte(uint8_t byte) {
    [fixtureLock lock];
    const uint8_t *bytes = fixtureData.bytes;
    size_t count = 0;
    for (size_t index = 0; index < fixtureData.length; index += 1) {
        if (bytes[index] == byte) {
            count += 1;
        }
    }
    [fixtureLock unlock];
    return count;
}

size_t ARISHFixtureSignalCount(void) {
    [fixtureLock lock];
    size_t count = fixtureSignals.count;
    [fixtureLock unlock];
    return count;
}

int32_t ARISHFixtureSignalAtIndex(size_t index) {
    [fixtureLock lock];
    int32_t signal = index < fixtureSignals.count
        ? fixtureSignals[index].intValue
        : -1;
    [fixtureLock unlock];
    return signal;
}
