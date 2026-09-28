#import <Foundation/Foundation.h>
#import "../USBLoopbackServer.h"
#import "../DeviceBridgeBackend.h"
#import "../USBTransportAuth.h"

// Real TCP/WebSocket/JSON server, fake auth crypto and fake USB backend.
// The separate auth tests cover cryptography; this executable never accesses USB.
static NSUInteger assertions, removals;
static NSDictionary *published;
static NSMutableArray *calls;
static NSMutableSet *finished;
static NSMutableDictionary<NSString *, void (^)(NSDictionary *)> *heldCompletions;
static NSLock *callLock;
static USBLoopbackServer *server;
static NSString * const extensionOrigin = @"safari-web-extension://11111111-2222-3333-4444-555555555555";
#define CHECK(...) do { assertions++; if (!(__VA_ARGS__)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #__VA_ARGS__); exit(1); } } while (0)

BOOL USBTransportHasSharedGroup(void) { return YES; }
NSDictionary *USBPublishTransportEndpoint(uint16_t port, NSError **error) {
    (void)error; published = @{@"port": @(port), @"instance": @"server-test"}; return published;
}
void USBRemoveTransportEndpoint(NSDictionary *endpoint) { CHECK(endpoint == published); removals++; }
NSDictionary *USBTransportBootstrap(NSString *profile, NSString *origin) { (void)profile; (void)origin; return @{}; }
NSDictionary *USBVerifyTransportToken(NSString *token, NSString *origin, NSDictionary *endpoint) {
    if (endpoint != published) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:token options:0];
    NSDictionary *claims = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![claims[@"origin"] isEqual:origin] || [claims[@"expires"] doubleValue] < NSDate.date.timeIntervalSince1970) return nil;
    return claims;
}
NSString *USBTransportProof(NSString *key, NSString *message) { return [NSString stringWithFormat:@"%@|%@", key, message]; }
BOOL USBTransportConstantEqual(NSString *a, NSString *b) { return [a isEqual:b]; }

@implementation DeviceBridgeBackend
+ (instancetype)sharedBackend { static DeviceBridgeBackend *backend; static dispatch_once_t once; dispatch_once(&once, ^{ backend = [self new]; }); return backend; }
- (NSDictionary *)handleMessage:(id)message profile:(NSString *)profile { (void)message; (void)profile; CHECK(NO); return @{}; }
- (void)handleMessage:(NSDictionary *)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion {
    [callLock lock]; [calls addObject:@{@"message": message, @"profile": profile}]; [callLock unlock];
    if ([@[@"serial.write", @"serial.abortWrite"] containsObject:message[@"op"]] && [message[@"args"][@"hold"] boolValue]) {
        NSString *key = [NSString stringWithFormat:@"%@:%@", message[@"session"], message[@"op"]];
        [callLock lock]; CHECK(!heldCompletions[key]); heldCompletions[key] = [completion copy]; [callLock unlock];
        return;
    }
    NSTimeInterval delay = [@[@"hold", @"slowGrant"] containsObject:message[@"op"]] ? 0.6 : 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        completion(@{@"ok": @YES, @"instance": @"test-instance", @"result": message[@"args"] ?: @{}});
        [callLock lock]; [finished addObject:[NSString stringWithFormat:@"%@:%@", message[@"session"], message[@"op"]]]; [callLock unlock];
    });
}
@end

static NSArray *snapshot(void) { [callLock lock]; NSArray *copy = calls.copy; [callLock unlock]; return copy; }
static BOOL hasFinished(NSString *session, NSString *op) { [callLock lock]; BOOL result = [finished containsObject:[NSString stringWithFormat:@"%@:%@", session, op]]; [callLock unlock]; return result; }
static void finishHeld(NSString *session, NSString *op) {
    NSString *key = [NSString stringWithFormat:@"%@:%@", session, op];
    [callLock lock]; void (^completion)(NSDictionary *) = heldCompletions[key]; [heldCompletions removeObjectForKey:key]; [callLock unlock];
    CHECK(completion != nil);
    completion(@{@"ok": @YES, @"instance": @"test-instance", @"result": @{}});
    [callLock lock]; [finished addObject:key]; [callLock unlock];
}
static void waitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (!condition() && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.01];
    CHECK(condition());
}
static NSURLSessionWebSocketTask *connectClient(NSString *origin) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"ws://127.0.0.1:%@/", published[@"port"]]]];
    [request setValue:origin forHTTPHeaderField:@"Origin"];
    NSURLSessionWebSocketTask *client = [NSURLSession.sharedSession webSocketTaskWithRequest:request];
    client.maximumMessageSize = 2 * 1024 * 1024;
    [client resume]; return client;
}
static void send(NSURLSessionWebSocketTask *client, NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:NULL];
    NSURLSessionWebSocketMessage *frame = [[NSURLSessionWebSocketMessage alloc] initWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); __block NSError *failure;
    [client sendMessage:frame completionHandler:^(NSError *error) { failure = error; dispatch_semaphore_signal(semaphore); }];
    CHECK(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    CHECK(failure == nil);
}
static NSDictionary *receive(NSURLSessionWebSocketTask *client) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0); __block NSError *failure; __block NSURLSessionWebSocketMessage *frame;
    [client receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *message, NSError *error) { frame = message; failure = error; dispatch_semaphore_signal(semaphore); }];
    CHECK(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0);
    if (failure) fprintf(stderr, "receive: %s\n", failure.description.UTF8String);
    CHECK(failure == nil && frame.type == NSURLSessionWebSocketMessageTypeString);
    id value = [NSJSONSerialization JSONObjectWithData:[frame.string dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    CHECK([value isKindOfClass:NSDictionary.class]); return value;
}
static NSString *token(NSString *origin, NSString *nonce) {
    NSDictionary *claims = @{@"profile": @"test-profile", @"origin": origin, @"nonce": nonce, @"expires": @(NSDate.date.timeIntervalSince1970 + 30), @"key": @"test-key"};
    return [[NSJSONSerialization dataWithJSONObject:claims options:0 error:NULL] base64EncodedStringWithOptions:0];
}
static void authenticate(NSURLSessionWebSocketTask *client, NSString *capability) {
    NSString *challenge = NSUUID.UUID.UUIDString;
    send(client, @{@"type": @"hello", @"token": capability, @"challenge": challenge});
    NSDictionary *reply = receive(client);
    CHECK([reply[@"type"] isEqual:@"challenge"]);
    CHECK([reply[@"proof"] isEqual:USBTransportProof(@"test-key", [NSString stringWithFormat:@"server:%@:%@", challenge, reply[@"challenge"]])]);
    send(client, @{@"type": @"authenticate", @"proof": USBTransportProof(@"test-key", [@"client:" stringByAppendingString:reply[@"challenge"]])});
    CHECK([receive(client)[@"type"] isEqual:@"ready"]);
}
static NSURLSessionWebSocketTask *authorized(void) { NSURLSessionWebSocketTask *client = connectClient(extensionOrigin); authenticate(client, token(extensionOrigin, NSUUID.UUID.UUIDString)); return client; }
static NSDictionary *request(NSString *identifier, NSString *session, NSString *op, NSDictionary *args) {
    return @{@"type": @"request", @"id": identifier, @"message": @{@"version": @1, @"session": session, @"origin": @"https://example.org", @"instance": @"test-instance", @"op": op, @"args": args}};
}
static void closeClient(NSURLSessionWebSocketTask *client) { [client cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil]; }

static void runTests(void) {
    @autoreleasepool {
        NSString *session = NSUUID.UUID.UUIDString;
        NSURLSessionWebSocketTask *client = authorized();
        send(client, request(@"one", session, @"enumerate", @{@"data": @"AAECA/7/", @"length": @6}));
        NSDictionary *reply = receive(client);
        CHECK([reply[@"type"] isEqual:@"response"] && [reply[@"id"] isEqual:@"one"]);
        CHECK([reply[@"response"][@"result"] isEqual:@{@"data": @"AAECA/7/", @"length": @6}]);
        NSString *firstProfile = snapshot().lastObject[@"profile"];
        CHECK([firstProfile hasPrefix:@"test-profile:"]);
        // Unsolicited input is private to the authenticated connection/document,
        // independent of pending request IDs or a slow request in flight.
        [DeviceBridgeBackend sharedBackend].eventHandler(@"wrong-profile", session, @{@"event":@"serial.data", @"deviceId":@"secret", @"data":@"AA=="});
        [DeviceBridgeBackend sharedBackend].eventHandler(firstProfile, @"unknown-document", @{@"event":@"hid.inputreport", @"deviceId":@"secret", @"data":@"AA=="});
        [DeviceBridgeBackend sharedBackend].eventHandler(firstProfile, session, @{@"event":@"serial.data", @"deviceId":@"port-1", @"data":@"AQID"});
        NSDictionary *event = receive(client);
        CHECK([event[@"type"] isEqual:@"event"] && [event[@"session"] isEqual:session]);
        CHECK([event[@"event"][@"deviceId"] isEqual:@"port-1"] && [event[@"event"][@"data"] isEqual:@"AQID"]);
        NSUInteger count = snapshot().count;
        NSMutableDictionary *bad = [request(@"wrong-origin", session, @"transferOut", @{}) mutableCopy];
        NSMutableDictionary *native = [bad[@"message"] mutableCopy]; native[@"origin"] = @"https://other.example"; bad[@"message"] = native;
        send(client, bad); CHECK([receive(client)[@"error"][@"name"] isEqual:@"SecurityError"]); CHECK(snapshot().count == count);

        // The complete maximum USB payload survives the transport unchanged.
        NSMutableData *bytes = [NSMutableData dataWithLength:1024 * 1024];
        for (NSUInteger i = 0; i < bytes.length; i++) ((unsigned char *)bytes.mutableBytes)[i] = (unsigned char)i;
        NSString *base64 = [bytes base64EncodedStringWithOptions:0];
        send(client, request(@"large", session, @"transferOut", @{@"data": base64, @"length": @(bytes.length)}));
        reply = receive(client); CHECK([reply[@"response"][@"result"][@"data"] isEqual:base64]); CHECK([reply[@"response"][@"result"][@"length"] unsignedIntegerValue] == bytes.length);

        // Admission deadlines run while an earlier backend operation is pending.
        send(client, request(@"hold", session, @"hold", @{}));
        send(client, request(@"expired", session, @"must-not-run", @{}));
        NSDictionary *expired = receive(client), *held = receive(client);
        CHECK([expired[@"id"] isEqual:@"expired"] && [expired[@"error"][@"name"] isEqual:@"TimeoutError"]);
        CHECK([held[@"id"] isEqual:@"hold"]);
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.op == %@", @"must-not-run"]] count] == 0);
        closeClient(client);
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.op == %@ AND profile == %@", @"closeSession", firstProfile]] count] == 1; });

        // A new connection gets a different namespace, even for the same profile.
        client = authorized();
        send(client, request(@"new", session, @"enumerate", @{})); receive(client);
        CHECK(![snapshot().lastObject[@"profile"] isEqual:firstProfile]);
        closeClient(client);

        NSString *used = token(extensionOrigin, NSUUID.UUID.UUIDString);
        client = connectClient(extensionOrigin); authenticate(client, used); closeClient(client);
        client = connectClient(extensionOrigin);
        send(client, @{@"type": @"hello", @"token": used, @"challenge": NSUUID.UUID.UUIDString});
        CHECK([receive(client)[@"error"][@"name"] isEqual:@"SecurityError"]);

        client = connectClient(extensionOrigin);
        send(client, @{@"type": @"hello", @"token": token(@"safari-web-extension://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", NSUUID.UUID.UUIDString), @"challenge": NSUUID.UUID.UUIDString});
        CHECK([receive(client)[@"error"][@"name"] isEqual:@"SecurityError"]);

        client = connectClient(extensionOrigin);
        send(client, @{@"type": @"hello", @"token": token(extensionOrigin, NSUUID.UUID.UUIDString), @"challenge": NSUUID.UUID.UUIDString});
        CHECK([receive(client)[@"type"] isEqual:@"challenge"]);
        send(client, @{@"type": @"authenticate", @"proof": @"wrong"});
        CHECK([receive(client)[@"error"][@"name"] isEqual:@"SecurityError"]);

        client = connectClient(extensionOrigin);
        send(client, request(@"unauthenticated", session, @"transferOut", @{}));
        CHECK([receive(client)[@"error"][@"name"] isEqual:@"SecurityError"]);

        // A grant already submitted before disconnection must be closed later;
        // queued operations from that dead connection must never reach USB.
        client = authorized(); NSString *closingSession = NSUUID.UUID.UUIDString;
        send(client, request(@"grant", closingSession, @"slowGrant", @{}));
        send(client, request(@"queued", closingSession, @"abandoned-write", @{}));
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.op == %@", @"slowGrant"]] count] == 1; });
        NSString *closingProfile = snapshot().lastObject[@"profile"];
        closeClient(client);
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.op == %@ AND profile == %@", @"closeSession", closingProfile]] count] == 1; });
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.op == %@", @"abandoned-write"]] count] == 0);

        // Mandatory document cleanup survives a saturated queue and the
        // ordinary admission deadline, and is performed exactly once.
        client = authorized(); NSString *fullSession = NSUUID.UUID.UUIDString;
        send(client, request(@"full-hold", fullSession, @"hold", @{}));
        for (NSUInteger i = 0; i < 31; i++) send(client, request([NSString stringWithFormat:@"full-%lu", (unsigned long)i], fullSession, @"saturated-write", @{}));
        send(client, request(@"overflow", fullSession, @"overflow-write", @{}));
        send(client, request(@"mandatory-close", fullSession, @"closeSession", @{}));
        NSMutableDictionary *replies = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < 34; i++) { NSDictionary *item = receive(client); replies[item[@"id"]] = item; }
        CHECK([replies[@"overflow"][@"error"][@"name"] isEqual:@"QuotaExceededError"]);
        CHECK([replies[@"mandatory-close"][@"response"][@"ok"] boolValue]);
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", fullSession, @"closeSession"]] count] == 1);
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", fullSession, @"saturated-write"]] count] == 0);
        closeClient(client);
        waitFor(^BOOL{ return hasFinished(fullSession, @"closeSession"); });
        [NSThread sleepForTimeInterval:0.05];
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", fullSession, @"closeSession"]] count] == 1);

        // Serial cancellation overtakes a blocked write and removes only queued
        // writes to the same peer/document/port. Another document is unaffected.
        client = authorized(); NSString *serialSession = NSUUID.UUID.UUIDString, *otherSerialSession = NSUUID.UUID.UUIDString;
        send(client, request(@"serial-enumerate", serialSession, @"serial.enumerate", @{})); receive(client);
        NSUInteger invalidStart = snapshot().count;
        for (NSString *invalid in @[@"version", @"instance", @"args", @"origin"]) {
            NSMutableDictionary *badAbort = [request([@"bad-abort-" stringByAppendingString:invalid], serialSession, @"serial.abortWrite", @{@"deviceId": @"serial-port"}) mutableCopy];
            NSMutableDictionary *body = [badAbort[@"message"] mutableCopy];
            body[invalid] = [invalid isEqual:@"version"] ? @YES : [invalid isEqual:@"args"] ? @[] : @"wrong-value";
            badAbort[@"message"] = body; send(client, badAbort);
            CHECK([receive(client)[@"type"] isEqual:@"error"]);
        }
        CHECK(snapshot().count == invalidStart);
        send(client, request(@"serial-active", serialSession, @"serial.write", @{@"deviceId": @"serial-port", @"hold": @YES}));
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", serialSession, @"serial.write"]] count] == 1; });
        send(client, request(@"serial-queued", serialSession, @"serial.write", @{@"deviceId": @"serial-port", @"marker": @"canceled"}));
        send(client, request(@"serial-other", otherSerialSession, @"serial.write", @{@"deviceId": @"serial-port", @"marker": @"other-document"}));
        dispatch_queue_t serialQueue = [server valueForKey:@"queue"];
        waitFor(^BOOL{
            __block NSUInteger count = 0;
            dispatch_sync(serialQueue, ^{
                for (id item in [server valueForKey:@"requests"]) if ([@[@"serial-queued", @"serial-other"] containsObject:[item valueForKey:@"identifier"]]) {
                    [item setValue:@(NSProcessInfo.processInfo.systemUptime + 5) forKey:@"deadline"]; count++;
                }
            }); return count == 2;
        });
        send(client, request(@"serial-abort", serialSession, @"serial.abortWrite", @{@"deviceId": @"serial-port"}));
        NSDictionary *canceledSerial = receive(client), *abortReply = receive(client);
        CHECK([canceledSerial[@"id"] isEqual:@"serial-queued"] && [canceledSerial[@"error"][@"name"] isEqual:@"AbortError"]);
        CHECK([abortReply[@"id"] isEqual:@"serial-abort"] && [abortReply[@"response"][@"ok"] boolValue]);
        CHECK(!hasFinished(serialSession, @"serial.write"));
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.args.marker == %@", @"canceled"]] count] == 0);
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@", otherSerialSession]] count] == 0);
        finishHeld(serialSession, @"serial.write");
        CHECK([receive(client)[@"id"] isEqual:@"serial-active"]);
        CHECK([receive(client)[@"id"] isEqual:@"serial-other"]);
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.args.marker == %@", @"other-document"]] count] == 1);
        send(client, request(@"serial-new-write", serialSession, @"serial.write", @{@"deviceId": @"serial-port"}));
        CHECK([receive(client)[@"response"][@"ok"] boolValue]);
        closeClient(client);
        waitFor(^BOOL{ return hasFinished(serialSession, @"closeSession"); });

        // Cancellation can also overtake a different active backend operation.
        // Its pending callback fences new writes and disconnect cleanup even
        // after that earlier operation has finished.
        client = authorized(); NSString *abortSession = NSUUID.UUID.UUIDString;
        send(client, request(@"abort-enumerate", abortSession, @"serial.enumerate", @{})); receive(client);
        send(client, request(@"abort-active-usb", abortSession, @"hold", @{}));
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", abortSession, @"hold"]] count] == 1; });
        send(client, request(@"held-abort", abortSession, @"serial.abortWrite", @{@"deviceId": @"serial-port", @"hold": @YES}));
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", abortSession, @"serial.abortWrite"]] count] == 1; });
        send(client, request(@"write-during-abort", abortSession, @"serial.write", @{@"deviceId": @"serial-port", @"marker": @"during-abort"}));
        CHECK([receive(client)[@"error"][@"name"] isEqual:@"AbortError"]);
        send(client, request(@"duplicate-abort", abortSession, @"serial.abortWrite", @{@"deviceId": @"serial-port"}));
        CHECK([receive(client)[@"error"][@"name"] isEqual:@"InvalidStateError"]);
        closeClient(client);
        waitFor(^BOOL{ return hasFinished(abortSession, @"hold"); });
        dispatch_sync(serialQueue, ^{});
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", abortSession, @"closeSession"]] count] == 0);
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.args.marker == %@", @"during-abort"]] count] == 0);
        finishHeld(abortSession, @"serial.abortWrite");
        waitFor(^BOOL{ return hasFinished(abortSession, @"closeSession"); });
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", abortSession, @"closeSession"]] count] == 1);

        // Model a fatal-error reply whose send completion is still pending.
        // The connection is closing but not yet closed when the active USB
        // request finishes. Queued operations must not dispatch in that window.
        client = authorized(); NSString *failingSession = NSUUID.UUID.UUIDString;
        send(client, request(@"failing-hold", failingSession, @"hold", @{}));
        send(client, request(@"failing-queued", failingSession, @"write-after-failure", @{}));
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", failingSession, @"hold"]] count] == 1; });
        NSString *failingProfile = snapshot().lastObject[@"profile"];
        dispatch_queue_t queue = [server valueForKey:@"queue"];
        dispatch_sync(queue, ^{
            for (id peer in [server valueForKey:@"peers"]) if ([[peer valueForKey:@"profile"] isEqual:failingProfile]) [peer setValue:@YES forKey:@"closing"];
            // Extend only this test request beyond the short test admission
            // deadline, so the regression cannot pass merely through expiry.
            for (id queued in [server valueForKey:@"requests"]) if ([[queued valueForKey:@"identifier"] isEqual:@"failing-queued"]) [queued setValue:@(NSProcessInfo.processInfo.systemUptime + 5) forKey:@"deadline"];
        });
        waitFor(^BOOL{ return hasFinished(failingSession, @"hold"); });
        dispatch_sync(queue, ^{});
        CHECK([[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", failingSession, @"write-after-failure"]] count] == 0);
        closeClient(client);
        waitFor(^BOOL{ return [[snapshot() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"message.session == %@ AND message.op == %@", failingSession, @"closeSession"]] count] == 1; });

        [server stop]; CHECK(removals == 1);
        printf("USBLoopbackServer: %lu assertions passed (real WebSockets, fake USB/auth)\n", (unsigned long)assertions);
        exit(0);
    }
}
int main(void) {
    @autoreleasepool {
        calls = [NSMutableArray array]; finished = [NSMutableSet set]; heldCompletions = [NSMutableDictionary dictionary]; callLock = [NSLock new]; server = [USBLoopbackServer new];
        [server startWithCompletion:^(NSError *error) {
            if (error) { fprintf(stderr, "START: %s\n", error.description.UTF8String); exit(1); }
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ runTests(); });
        }];
        dispatch_main();
    }
}
