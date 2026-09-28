#import "DeviceBridgeBackend.h"
#import "DevicePermissionStore.h"
#import "USBBackend.h"
#import "SerialBackend.h"
#import "HIDBackend.h"

static BOOL BridgeString(id value, NSUInteger min, NSUInteger max) {
    return [value isKindOfClass:NSString.class] && [value length] >= min && [value length] <= max;
}
static BOOL BridgeFalse(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() && ![value boolValue];
}
static BOOL BridgeOrigin(id value) {
    if (!BridgeString(value, 1, 2048)) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:value];
    if (!url.host.length || url.user || url.password || url.query || url.fragment || url.path.length) return NO;
    return [url.scheme isEqual:@"https"] || ([url.scheme isEqual:@"http"] && [@[@"localhost", @"127.0.0.1", @"::1", @"[::1]"] containsObject:url.host.lowercaseString]);
}
static NSString *BridgeKey(NSArray *parts) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:parts options:0 error:nil] encoding:NSUTF8StringEncoding];
}
@interface DeviceBridgeBackend ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t timer;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary *> *sessions;
@property(nonatomic) DevicePermissionStore *permissions;
@property(nonatomic) NSUInteger permissionRevision;
@end
@implementation DeviceBridgeBackend
+ (instancetype)sharedBackend {
    static DeviceBridgeBackend *backend; static dispatch_once_t once;
    dispatch_once(&once, ^{ backend = [self new]; }); return backend;
}
- (instancetype)init { return [self initWithPermissionStore:[[DevicePermissionStore alloc] initWithURL:DevicePermissionStore.defaultURL]]; }
- (instancetype)initWithPermissionStore:(DevicePermissionStore *)store {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("org.webtilp.safariwebusb.devices", DISPATCH_QUEUE_SERIAL);
        _sessions = [NSMutableDictionary dictionary]; _permissions = store;
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
            for (NSString *key in self.sessions.allKeys) if (now - [self.sessions[key][@"lastSeen"] doubleValue] > 60) [self close:key];
        });
        dispatch_resume(_timer);
    }
    return self;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
- (void)close:(NSString *)key {
    NSDictionary *session = self.sessions[key];
    if (!session) return;
    [[SerialBackend sharedBackend] closeSession:key]; [[HIDBackend sharedBackend] closeSession:key];
    [[USBBackend sharedBackend] handleMessage:@{@"version":@1, @"op":@"closeSession", @"args":@{},
        @"session":session[@"session"], @"origin":session[@"origin"], @"instance":[USBBackend sharedBackend].instance}
        profile:session[@"profile"] completion:^(NSDictionary *result) { (void)result; }];
    [self.sessions removeObjectForKey:key];
}
- (NSDictionary *)response:(NSDictionary *)response {
    NSMutableDictionary *result = [response mutableCopy]; result[@"instance"] = [USBBackend sharedBackend].instance; return result;
}
- (NSDictionary *)success:(id)value { return [self response:@{@"ok":@YES, @"result":value ?: NSNull.null}]; }
- (NSDictionary *)failure:(NSString *)name message:(NSString *)message {
    return [self response:@{@"ok":@NO, @"error":@{@"name":name, @"message":message}}];
}
- (BOOL)remembering:(NSDictionary *)session { return [session[@"permissionProfile"] length] && ![session[@"privateBrowsing"] boolValue]; }
- (NSMutableDictionary *)grants:(NSMutableDictionary *)session kind:(NSString *)kind {
    NSMutableDictionary *grants = session[@"grants"][kind];
    if (!grants) { grants = [NSMutableDictionary dictionary]; session[@"grants"][kind] = grants; }
    return grants;
}
- (void)inventory:(NSString *)kind completion:(void (^)(NSArray *))completion {
    void (^reply)(NSArray *) = ^(NSArray *records) { dispatch_async(self.queue, ^{ completion(records); }); };
    if ([kind isEqual:@"usb"]) [[USBBackend sharedBackend] permissionDevicesWithCompletion:reply];
    else if ([kind isEqual:@"serial"]) [[SerialBackend sharedBackend] permissionDevicesWithCompletion:reply];
    else [[HIDBackend sharedBackend] permissionDevicesWithCompletion:reply];
}
- (void)perform:(NSString *)operation kind:(NSString *)kind args:(NSDictionary *)args session:(NSMutableDictionary *)session key:(NSString *)key completion:(void (^)(NSDictionary *))completion {
    // All events and replies enter the same router queue, preserving cancelRead's fence.
    void (^reply)(NSDictionary *) = ^(NSDictionary *result) { dispatch_async(self.queue, ^{ completion([self response:result]); }); };
    if ([kind isEqual:@"usb"]) [[USBBackend sharedBackend] handleMessage:@{@"version":@1, @"op":operation, @"args":args,
        @"session":session[@"session"], @"origin":session[@"origin"], @"instance":[USBBackend sharedBackend].instance}
        profile:session[@"profile"] completion:reply];
    else if ([kind isEqual:@"serial"]) [[SerialBackend sharedBackend] handleOperation:operation args:args session:key completion:reply];
    else [[HIDBackend sharedBackend] handleOperation:operation args:args session:key completion:reply];
}
- (BOOL)current:(NSMutableDictionary *)session key:(NSString *)key revision:(NSUInteger)revision {
    return self.sessions[key] == session && revision == self.permissionRevision;
}
- (void)undoGrant:(NSString *)identifier kind:(NSString *)kind session:(NSMutableDictionary *)session key:(NSString *)key completion:(void (^)(NSDictionary *))completion {
    [self perform:@"forget" kind:kind args:@{@"deviceId":identifier} session:session key:key completion:^(NSDictionary *ignored) {
        (void)ignored; completion([self failure:@"SecurityError" message:@"Device permission changed while the request was pending. Retry the request."]);
    }];
}
- (void)grant:(NSString *)identifier kind:(NSString *)kind session:(NSMutableDictionary *)session key:(NSString *)key completion:(void (^)(NSDictionary *))completion {
    NSUInteger revision = self.permissionRevision;
    [self inventory:kind completion:^(NSArray *records) {
        if (![self current:session key:key revision:revision]) { completion([self failure:@"SecurityError" message:@"Document or device permission changed."]); return; }
        NSDictionary *selected = nil; NSUInteger matches = 0;
        for (NSDictionary *record in records) if ([record[@"device"][@"id"] isEqual:identifier]) { selected = record; break; }
        if (selected) for (NSDictionary *record in records) if ([record[@"identity"] isEqual:selected[@"identity"]]) matches++;
        if (!selected) { completion([self failure:@"NotFoundError" message:@"Device disconnected before permission could be granted."]); return; }
        [self perform:@"grant" kind:kind args:@{@"deviceId":identifier} session:session key:key completion:^(NSDictionary *result) {
            if (![result[@"ok"] boolValue]) { completion(result); return; }
            if (![self current:session key:key revision:revision]) { [self undoGrant:identifier kind:kind session:session key:key completion:completion]; return; }
            [self grants:session kind:kind][identifier] = selected;
            if ([self remembering:session] && matches == 1) {
                NSString *name = selected[@"device"][@"productName"];
                if (!BridgeString(name, 1, 512)) name = [kind stringByAppendingString:@" device"];
                NSError *error = nil;
                if (![self.permissions rememberProfile:session[@"permissionProfile"] origin:session[@"origin"] kind:kind
                    identity:selected[@"identity"] name:name durable:[selected[@"durable"] boolValue] error:&error]) {
                    [[self grants:session kind:kind] removeObjectForKey:identifier];
                    [self perform:@"forget" kind:kind args:@{@"deviceId":identifier} session:session key:key completion:^(NSDictionary *ignored) {
                        (void)ignored; completion([self failure:@"NotReadableError" message:error.localizedDescription ?: @"Could not save device permission."]);
                    }]; return;
                }
            }
            completion(result);
        }];
    }];
}
- (void)restore:(NSArray *)records index:(NSUInteger)index kind:(NSString *)kind operation:(NSString *)operation session:(NSMutableDictionary *)session key:(NSString *)key revision:(NSUInteger)revision completion:(void (^)(NSDictionary *))completion {
    if (![self current:session key:key revision:revision]) { completion([self failure:@"SecurityError" message:@"Document or device permission changed."]); return; }
    if (index >= records.count) {
        [self perform:operation kind:kind args:@{} session:session key:key completion:^(NSDictionary *result) {
            completion([self current:session key:key revision:revision] ? result : [self failure:@"SecurityError" message:@"Document or device permission changed."]);
        }]; return;
    }
    NSDictionary *record = records[index]; NSString *identifier = record[@"device"][@"id"];
    [self perform:@"grant" kind:kind args:@{@"deviceId":identifier} session:session key:key completion:^(NSDictionary *result) {
        if (![self current:session key:key revision:revision]) {
            if ([result[@"ok"] boolValue]) [self undoGrant:identifier kind:kind session:session key:key completion:completion];
            else completion([self failure:@"SecurityError" message:@"Document or device permission changed."]);
            return;
        }
        if ([result[@"ok"] boolValue]) [self grants:session kind:kind][identifier] = record;
        [self restore:records index:index+1 kind:kind operation:operation session:session key:key revision:revision completion:completion];
    }];
}
- (void)list:(NSString *)operation kind:(NSString *)kind session:(NSMutableDictionary *)session key:(NSString *)key completion:(void (^)(NSDictionary *))completion {
    if (![self remembering:session]) { [self perform:operation kind:kind args:@{} session:session key:key completion:completion]; return; }
    NSUInteger revision = self.permissionRevision;
    [self inventory:kind completion:^(NSArray *inventory) {
        NSMutableDictionary *counts = [NSMutableDictionary dictionary];
        for (NSDictionary *record in inventory) counts[record[@"identity"]] = @([counts[record[@"identity"]] unsignedIntegerValue] + 1);
        NSMutableArray *restore = [NSMutableArray array];
        for (NSDictionary *record in inventory) if ([counts[record[@"identity"]] unsignedIntegerValue] == 1 &&
            [self.permissions recordForProfile:session[@"permissionProfile"] origin:session[@"origin"] kind:kind identity:record[@"identity"]]) [restore addObject:record];
        [self restore:restore index:0 kind:kind operation:operation session:session key:key revision:revision completion:completion];
    }];
}
- (void)revokeRecords:(NSArray *)records extraSession:(NSMutableDictionary *)extra kind:(NSString *)extraKind identity:(NSString *)extraIdentity completion:(void (^)(void))completion {
    // Bump before any asynchronous backend work. In-flight grants cannot recreate a revoked permission.
    self.permissionRevision++;
    dispatch_group_t pending = dispatch_group_create();
    for (NSString *key in self.sessions.allKeys) {
        NSMutableDictionary *session = self.sessions[key];
        for (NSString *kind in [session[@"grants"] allKeys]) {
            NSMutableDictionary *grants = [self grants:session kind:kind];
            for (NSString *identifier in grants.allKeys) {
                NSString *identity = grants[identifier][@"identity"]; BOOL revoke = NO;
                for (NSDictionary *record in records) if ([self remembering:session] &&
                    [record[@"profile"] isEqual:session[@"permissionProfile"]] && [record[@"origin"] isEqual:session[@"origin"]] &&
                    [record[@"kind"] isEqual:kind] && [record[@"identity"] isEqual:identity]) { revoke = YES; break; }
                if (session == extra && [extraKind isEqual:kind] && [extraIdentity isEqual:identity]) revoke = YES;
                if (!revoke) continue;
                [grants removeObjectForKey:identifier];
                if (self.eventHandler) self.eventHandler(session[@"profile"], session[@"session"], @{@"event":@"permissions.revoked", @"kind":kind, @"deviceId":identifier});
                dispatch_group_enter(pending);
                [self perform:@"forget" kind:kind args:@{@"deviceId":identifier} session:session key:key completion:^(NSDictionary *ignored) {
                    (void)ignored; dispatch_group_leave(pending);
                }];
            }
        }
    }
    dispatch_group_notify(pending, self.queue, completion);
}
- (void)forget:(NSString *)identifier kind:(NSString *)kind session:(NSMutableDictionary *)session key:(NSString *)key completion:(void (^)(NSDictionary *))completion {
    NSDictionary *capture = [self grants:session kind:kind][identifier];
    if (!capture) { [self perform:@"forget" kind:kind args:@{@"deviceId":identifier} session:session key:key completion:completion]; return; }
    NSDictionary *record = [self remembering:session] ? [self.permissions recordForProfile:session[@"permissionProfile"] origin:session[@"origin"] kind:kind identity:capture[@"identity"]] : nil;
    NSError *error = nil;
    if (record && ![self.permissions removeIDs:@[record[@"id"]] profile:session[@"permissionProfile"] error:&error]) {
        completion([self failure:@"NotReadableError" message:error.localizedDescription ?: @"Could not remove device permission."]); return;
    }
    [self revokeRecords:record ? @[record] : @[] extraSession:session kind:kind identity:capture[@"identity"] completion:^{ completion([self success:nil]); }];
}
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion {
    [self handleMessage:message profile:profile permissionProfile:nil completion:completion];
}
- (void)handleMessage:(id)message profile:(NSString *)profile permissionProfile:(NSString *)permissionProfile completion:(void (^)(NSDictionary *))completion {
    dispatch_async(self.queue, ^{
        if (![message isKindOfClass:NSDictionary.class] || !BridgeString(message[@"op"], 1, 64)) {
            completion([self failure:@"TypeError" message:@"Invalid device bridge message."]); return;
        }
        NSString *op = message[@"op"]; id version = message[@"version"];
        if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() || ![version isEqual:@1] || ![message[@"args"] isKindOfClass:NSDictionary.class]) {
            completion([self failure:@"TypeError" message:@"Invalid protocol version or arguments."]); return;
        }
        NSString *identifier = message[@"session"], *origin = message[@"origin"];
        if (!BridgeString(profile, 1, 256) || !BridgeString(identifier, 16, 128) || !BridgeOrigin(origin) || (permissionProfile && !BridgeString(permissionProfile, 1, 256))) {
            completion([self failure:@"SecurityError" message:@"A trusted profile and secure document session are required."]); return;
        }
        BOOL serial = [op hasPrefix:@"serial."], hid = [op hasPrefix:@"hid."];
        NSString *kind = serial ? @"serial" : hid ? @"hid" : @"usb";
        NSString *operation = serial ? [op substringFromIndex:7] : hid ? [op substringFromIndex:4] : op;
        BOOL enumerate = [operation isEqual:@"enumerate"], list = [operation isEqual:@"getDevices"] || (serial && [operation isEqual:@"getPorts"]);
        BOOL bootstrap = enumerate || list;
        if ((!bootstrap || (!enumerate && message[@"instance"])) && ![[USBBackend sharedBackend].instance isEqual:message[@"instance"]]) {
            completion([self failure:@"InvalidStateError" message:@"The native bridge restarted. Choose the device again."]); return;
        }
        NSString *key = BridgeKey(@[profile, identifier]); NSMutableDictionary *session = self.sessions[key];
        NSNumber *privateBrowsing = @(!BridgeFalse(message[@"privateBrowsing"])); NSString *permissionNamespace = permissionProfile ?: @"";
        if (session && (![session[@"origin"] isEqual:origin] || ![session[@"privateBrowsing"] isEqual:privateBrowsing] || ![session[@"permissionProfile"] isEqual:permissionNamespace])) {
            completion([self failure:@"SecurityError" message:@"Document origin or permission context does not match its session."]); return;
        }
        if ([op isEqual:@"closeSession"]) { [self close:key]; completion([self success:nil]); return; }
        if (!session) {
            if (!bootstrap) { completion([self failure:@"InvalidStateError" message:@"Document session expired. Choose the device again."]); return; }
            if (self.sessions.count >= 1024) { completion([self failure:@"QuotaExceededError" message:@"Too many device sessions."]); return; }
            session = [@{@"profile":profile, @"session":identifier, @"origin":origin, @"permissionProfile":permissionNamespace,
                @"privateBrowsing":privateBrowsing, @"grants":[NSMutableDictionary dictionary]} mutableCopy];
            self.sessions[key] = session;
        }
        session[@"lastSeen"] = @(NSProcessInfo.processInfo.systemUptime);
        // Detached objects still need their captured identity for forget(). This
        // document lease is independent of a currently open backend USB session.
        if ([op isEqual:@"heartbeat"]) { completion([self success:nil]); return; }
        if (list) { [self list:operation kind:kind session:session key:key completion:completion]; return; }
        if ([operation isEqual:@"grant"] || [operation isEqual:@"forget"]) {
            NSString *deviceId = message[@"args"][@"deviceId"];
            if (!BridgeString(deviceId, 1, 128)) { completion([self failure:@"TypeError" message:@"Invalid device identifier."]); return; }
            if ([operation isEqual:@"grant"]) [self grant:deviceId kind:kind session:session key:key completion:completion];
            else [self forget:deviceId kind:kind session:session key:key completion:completion];
            return;
        }
        [self perform:operation kind:kind args:message[@"args"] session:session key:key completion:completion];
    });
}
- (void)handlePermissionMessage:(id)message permissionProfile:(NSString *)permissionProfile completion:(void (^)(NSDictionary *))completion {
    dispatch_async(self.queue, ^{
        if (![message isKindOfClass:NSDictionary.class] || !BridgeFalse(message[@"privateBrowsing"]) || !BridgeString(permissionProfile, 1, 256)) {
            completion([self failure:@"SecurityError" message:@"Saved device permissions are unavailable in private browsing."]); return;
        }
        id version = message[@"version"];
        if (![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() || ![version isEqual:@1] || ![message[@"args"] isKindOfClass:NSDictionary.class]) {
            completion([self failure:@"TypeError" message:@"Invalid permission manager request."]); return;
        }
        NSString *op = message[@"op"]; NSArray *records = [self.permissions recordsForProfile:permissionProfile];
        if ([op isEqual:@"permissions.list"]) {
            NSMutableArray *result = [NSMutableArray array];
            for (NSDictionary *record in records) [result addObject:[record dictionaryWithValuesForKeys:@[@"id", @"origin", @"kind", @"name", @"durable"]]];
            completion([self success:result]); return;
        }
        NSMutableArray *removed = [NSMutableArray array];
        if ([op isEqual:@"permissions.clear"]) [removed addObjectsFromArray:records];
        else if ([op isEqual:@"permissions.revoke"] && BridgeString(message[@"args"][@"id"], 1, 64)) {
            for (NSDictionary *record in records) if ([record[@"id"] isEqual:message[@"args"][@"id"]]) [removed addObject:record];
        } else { completion([self failure:@"TypeError" message:@"Invalid permission manager operation."]); return; }
        NSError *error = nil;
        if (![self.permissions removeIDs:[removed valueForKey:@"id"] profile:permissionProfile error:&error]) {
            completion([self failure:@"NotReadableError" message:error.localizedDescription ?: @"Could not remove device permission."]); return;
        }
        [self revokeRecords:removed extraSession:nil kind:nil identity:nil completion:^{ completion([self success:nil]); }];
    });
}
@end
