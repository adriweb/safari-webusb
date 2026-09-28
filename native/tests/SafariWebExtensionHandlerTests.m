#import <SafariServices/SafariServices.h>
#import "../USBBackend.h"

// Compile the production handler below with a deterministic monotonic clock.
// The backend and context are fakes: no Safari installation or USB access.
static NSUInteger assertions;
#define CHECK(expression) do { assertions++; if (!(expression)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); exit(1); } } while (0)
static uint64_t clockNow = 100 * NSEC_PER_MSEC;
static NSUInteger backendCalls, contextCompletions;
static uint64_t lastCompletionTime;
static id lastMessage;
static NSString *lastProfile;
static NSDictionary *lastResponse;
static void (^backendCompletion)(NSDictionary *);

@interface ScheduledReply : NSObject
@property uint64_t deadline;
@property(copy) dispatch_block_t block;
@end
@implementation ScheduledReply
@end
static NSMutableArray<ScheduledReply *> *scheduledReplies;

static dispatch_time_t fakeDispatchTime(dispatch_time_t when, int64_t delta) {
    CHECK(when == DISPATCH_TIME_NOW);
    CHECK(delta == 40 * NSEC_PER_MSEC);
    return clockNow + delta;
}
static void fakeDispatchAfter(dispatch_time_t deadline, dispatch_queue_t queue, dispatch_block_t block) {
    CHECK(queue == dispatch_get_main_queue());
    ScheduledReply *reply = [ScheduledReply new];
    reply.deadline = deadline;
    reply.block = block;
    [scheduledReplies addObject:reply];
}
static void advanceTo(uint64_t time) {
    clockNow = time;
    while (scheduledReplies.count && scheduledReplies.firstObject.deadline <= clockNow) {
        ScheduledReply *reply = scheduledReplies.firstObject;
        [scheduledReplies removeObjectAtIndex:0];
        reply.block();
    }
}
static void replyFromBackend(NSDictionary *response) {
    CHECK(backendCompletion != nil);
    void (^completion)(NSDictionary *) = backendCompletion;
    backendCompletion = nil;
    completion(response);
}

@implementation USBBackend
+ (instancetype)sharedBackend {
    static USBBackend *backend;
    if (!backend) backend = [self new];
    return backend;
}
- (NSDictionary *)handleMessage:(id)message profile:(NSString *)profile {
    (void)message; (void)profile;
    CHECK(NO); // The handler must continue using the asynchronous USB backend.
    return @{};
}
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion {
    CHECK(backendCompletion == nil);
    backendCalls++;
    lastMessage = message;
    lastProfile = profile;
    backendCompletion = completion;
}
@end

// Include the actual implementation, substituting only dispatch timing. This
// checks its captured absolute deadline without fragile wall-clock assertions.
#define dispatch_time fakeDispatchTime
#define dispatch_after fakeDispatchAfter
#import "../SafariWebExtensionHandler.m"
#undef dispatch_after
#undef dispatch_time

@interface FakeContext : NSExtensionContext
@property(copy) NSArray *items;
@end
@implementation FakeContext
- (NSArray *)inputItems { return self.items; }
- (void)completeRequestReturningItems:(NSArray *)items completionHandler:(void (^)(BOOL))completionHandler {
    CHECK(completionHandler == nil);
    CHECK(items.count == 1);
    contextCompletions++;
    lastCompletionTime = clockNow;
    lastResponse = [items.firstObject userInfo][SFExtensionMessageKey];
}
@end
static FakeContext *context(NSDictionary *message) {
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{SFExtensionMessageKey: message};
    FakeContext *context = [FakeContext new];
    context.items = @[item];
    return context;
}

int main(void) {
    @autoreleasepool {
        scheduledReplies = [NSMutableArray array];
        SafariWebExtensionHandler *handler = [SafariWebExtensionHandler new];
        NSDictionary *success = @{@"ok": @YES, @"instance": @"one", @"result": @{@"bytesWritten": @4}};
        NSDictionary *failure = @{@"ok": @NO, @"instance": @"one", @"error": @{@"name": @"TimeoutError"}};
        NSDictionary *write = @{@"version": @1, @"op": @"transferOut", @"args": @{@"data": @"AQIDBA=="}};
        __weak FakeContext *releasedContext;
        @autoreleasepool {
            FakeContext *request = context(write);
            releasedContext = request;
            [handler beginRequestWithExtensionContext:request];
            CHECK(backendCalls == 1); // Submission is immediate, not paced.
            CHECK([lastMessage isEqual:write]);
            CHECK([lastProfile isEqual:@"legacy-default"]);
            CHECK(scheduledReplies.count == 0);
        }
        CHECK(releasedContext != nil); // Retained while the backend is pending.
        replyFromBackend(success);
        CHECK(scheduledReplies.count == 1);
        CHECK(scheduledReplies.firstObject.deadline == 140 * NSEC_PER_MSEC);
        CHECK(contextCompletions == 0);
        advanceTo(139 * NSEC_PER_MSEC);
        CHECK(contextCompletions == 0);
        @autoreleasepool { advanceTo(140 * NSEC_PER_MSEC); }
        CHECK(contextCompletions == 1);
        CHECK(lastCompletionTime == 140 * NSEC_PER_MSEC);
        CHECK(lastResponse == success);
        CHECK(releasedContext == nil); // No context survives the reply block.
        advanceTo(1000 * NSEC_PER_MSEC);
        CHECK(backendCalls == 1 && contextCompletions == 1); // No USB replay.

        // A slow USB call has already consumed the interval: completing it must
        // schedule an expired deadline, not start another 40 ms delay.
        [handler beginRequestWithExtensionContext:context(write)];
        CHECK(backendCalls == 2);
        clockNow = 6000 * NSEC_PER_MSEC;
        replyFromBackend(failure);
        CHECK(scheduledReplies.firstObject.deadline == 1040 * NSEC_PER_MSEC);
        advanceTo(clockNow);
        CHECK(contextCompletions == 2);
        CHECK(lastCompletionTime == 6000 * NSEC_PER_MSEC);
        CHECK(lastResponse == failure); // Errors are returned unchanged once.
        CHECK(backendCalls == 2);

        // Time spent inside the handler/backend counts toward the same deadline.
        clockNow = 7000 * NSEC_PER_MSEC;
        [handler beginRequestWithExtensionContext:context(@{@"version": @0})];
        clockNow = 7025 * NSEC_PER_MSEC;
        replyFromBackend(failure);
        CHECK(scheduledReplies.firstObject.deadline == 7040 * NSEC_PER_MSEC);
        advanceTo(7039 * NSEC_PER_MSEC);
        CHECK(contextCompletions == 2);
        advanceTo(7040 * NSEC_PER_MSEC);
        CHECK(contextCompletions == 3);
        CHECK(backendCalls == 3);
        CHECK(scheduledReplies.count == 0 && backendCompletion == nil);
        printf("SafariWebExtensionHandler: %lu assertions passed\n", (unsigned long)assertions);
    }
}
