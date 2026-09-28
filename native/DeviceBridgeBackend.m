#import "DeviceBridgeBackend.h"
#import "USBBackend.h"
#import "SerialBackend.h"
#import "HIDBackend.h"

static BOOL BridgeString(id value, NSUInteger min, NSUInteger max) {
    return [value isKindOfClass:NSString.class] && [value length] >= min && [value length] <= max;
}
static BOOL BridgeOrigin(id value) {
    if (!BridgeString(value, 1, 2048)) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    if (!url.host.length || url.user || url.password || url.query || url.fragment || url.path.length) return NO;
    return [url.scheme isEqual:@"https"] || ([url.scheme isEqual:@"http"] && [@[@"localhost", @"127.0.0.1", @"::1", @"[::1]"] containsObject:url.host.lowercaseString]);
}
@interface DeviceBridgeBackend ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary *> *sessions;
@end
@implementation DeviceBridgeBackend
+ (instancetype)sharedBackend {
    static DeviceBridgeBackend *backend;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ backend = [self new]; });
    return backend;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("org.webtilp.safariwebusb.devices", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableDictionary dictionary];
        __weak typeof(self) weakSelf = self;
        void (^event)(NSString *, NSDictionary *) = ^(NSString *key, NSDictionary *value) {
            DeviceBridgeBackend *self = weakSelf;
            if (!self) return;
            dispatch_async(self.queue, ^{
                NSDictionary *session = self.sessions[key];
                if (session && self.eventHandler) self.eventHandler(session[@"profile"], session[@"session"], value);
            });
        };
        [SerialBackend sharedBackend].eventHandler = event;
        [HIDBackend sharedBackend].eventHandler = event;
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(_timer, ^{
            DeviceBridgeBackend *self = weakSelf;
            NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            for (NSString *key in self.sessions.allKeys) {
                if (now - [self.sessions[key][@"lastSeen"] doubleValue] > 60) [self close:key];
            }
        });
        dispatch_resume(_timer);
    }
    return self;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
- (void)close:(NSString *)key {
    [[SerialBackend sharedBackend] closeSession:key];
    [[HIDBackend sharedBackend] closeSession:key];
    [self.sessions removeObjectForKey:key];
}
- (NSDictionary *)response:(NSDictionary *)response {
    NSMutableDictionary *result = [response mutableCopy];
    result[@"instance"] = [USBBackend sharedBackend].instance;
    return result;
}
- (NSDictionary *)failure:(NSString *)name message:(NSString *)message {
    return [self response:@{@"ok": @NO, @"error": @{@"name":name, @"message":message}}];
}
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion {
    dispatch_async(self.queue, ^{
        if (![message isKindOfClass:NSDictionary.class] || !BridgeString(message[@"op"], 1, 64)) {
            completion([self failure:@"TypeError" message:@"Invalid device bridge message."]); return;
        }
        NSString *op = message[@"op"];
        BOOL serial = [op hasPrefix:@"serial."], hid = [op hasPrefix:@"hid."];
        if (!serial && !hid && ![op isEqual:@"closeSession"]) {
            [[USBBackend sharedBackend] handleMessage:message profile:profile completion:completion]; return;
        }
        id version = message[@"version"];
        if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() || ![version isEqual:@1] || ![message[@"args"] isKindOfClass:NSDictionary.class]) {
            completion([self failure:@"TypeError" message:@"Invalid protocol version or arguments."]); return;
        }
        NSString *identifier = message[@"session"], *origin = message[@"origin"];
        if (!BridgeString(profile, 1, 256) || !BridgeString(identifier, 16, 128) || !BridgeOrigin(origin)) {
            completion([self failure:@"SecurityError" message:@"A trusted profile and secure document session are required."]); return;
        }
        BOOL enumerate = [op isEqual:@"serial.enumerate"] || [op isEqual:@"hid.enumerate"];
        if (!enumerate && ![[USBBackend sharedBackend].instance isEqual:message[@"instance"]]) {
            completion([self failure:@"InvalidStateError" message:@"The native bridge restarted. Choose the device again."]); return;
        }
        NSString *key = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[profile, identifier] options:0 error:nil] encoding:NSUTF8StringEncoding];
        NSMutableDictionary *session = self.sessions[key];
        if (session && ![session[@"origin"] isEqual:origin]) {
            completion([self failure:@"SecurityError" message:@"Document origin does not match its session."]); return;
        }
        if ([op isEqual:@"closeSession"]) {
            [self close:key];
            [[USBBackend sharedBackend] handleMessage:message profile:profile completion:completion]; return;
        }
        if (!session) {
            if (!enumerate) { completion([self failure:@"InvalidStateError" message:@"Document session expired. Choose the device again."]); return; }
            if (self.sessions.count >= 1024) { completion([self failure:@"QuotaExceededError" message:@"Too many device sessions."]); return; }
            session = [@{@"profile":profile, @"session":identifier, @"origin":origin} mutableCopy];
            self.sessions[key] = session;
        }
        session[@"lastSeen"] = @(NSProcessInfo.processInfo.systemUptime);
        NSString *operation = [op substringFromIndex:serial ? 7 : 4];
        // Preserve backend event/reply ordering, particularly cancelRead's fence.
        // Both enter this queue before reaching the socket queue.
        void (^reply)(NSDictionary *) = ^(NSDictionary *result) {
            dispatch_async(self.queue, ^{ completion([self response:result]); });
        };
        if (serial) [[SerialBackend sharedBackend] handleOperation:operation args:message[@"args"] session:key completion:reply];
        else [[HIDBackend sharedBackend] handleOperation:operation args:message[@"args"] session:key completion:reply];
    });
}
@end
