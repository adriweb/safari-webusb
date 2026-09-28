#import "../DeviceBridgeBackend.h"
#import "../DevicePermissionStore.h"
#import "../USBBackend.h"
#import "../SerialBackend.h"
#import "../HIDBackend.h"
static NSUInteger assertions;
static NSMutableArray *serialCalls, *hidCalls, *closedSerial, *closedHID, *usbCalls;
static NSMutableDictionary *inventories, *nativeGrants;
static DeviceBridgeBackend *router;
static NSString *holdInventory, *holdGrant;
static void (^pendingInventory)(NSArray *);
static void (^pendingGrant)(NSDictionary *);
static NSDictionary *pendingGrantResult;
static dispatch_semaphore_t held;
static void inventory(NSString *kind, void (^completion)(NSArray *)) {
    if ([holdInventory isEqual:kind]) { pendingInventory=[completion copy]; dispatch_semaphore_signal(held); return; }
    completion(inventories[kind] ?: @[]);
}
static NSDictionary *fakeOperation(NSString *kind, NSString *op, NSDictionary *args, NSString *session) {
    NSString *key=[kind stringByAppendingString:session];
    NSMutableSet *grants=nativeGrants[key]; if (!grants) nativeGrants[key]=grants=[NSMutableSet set];
    id result=NSNull.null;
    if ([op isEqual:@"closeSession"]) [grants removeAllObjects];
    else if ([op isEqual:@"forget"]) [grants removeObject:args[@"deviceId"]];
    else if ([op isEqual:@"grant"]) {
        for (NSDictionary *record in inventories[kind]) if ([record[@"device"][@"id"] isEqual:args[@"deviceId"]]) result=record[@"device"];
        if (result==NSNull.null) return @{@"ok":@NO,@"error":@{@"name":@"NotFoundError",@"message":@"Unplugged"}};
        [grants addObject:args[@"deviceId"]];
    } else if ([op isEqual:@"getDevices"] || [op isEqual:@"getPorts"] || [op isEqual:@"enumerate"]) {
        NSMutableArray *devices=[NSMutableArray array];
        for (NSDictionary *record in inventories[kind]) if ([op isEqual:@"enumerate"] || [grants containsObject:record[@"device"][@"id"]]) [devices addObject:record[@"device"]];
        result=devices;
    }
    return @{@"ok":@YES,@"result":result};
}
static void operationReply(NSString *kind, NSString *op, NSDictionary *result, void (^completion)(NSDictionary *)) {
    if ([holdGrant isEqual:kind] && [op isEqual:@"grant"]) { pendingGrant=[completion copy]; pendingGrantResult=result; dispatch_semaphore_signal(held); return; }
    completion(result);
}
#define CHECK(...) do { assertions++; if (!(__VA_ARGS__)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
@implementation USBBackend
+ (instancetype)sharedBackend { static USBBackend *backend; static dispatch_once_t once; dispatch_once(&once,^{backend=[self new];}); return backend; }
- (NSString *)instance { return @"epoch-1"; }
- (NSDictionary *)handleMessage:(id)message profile:(NSString *)profile {
    NSString *session=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[profile,message[@"session"]] options:0 error:nil] encoding:NSUTF8StringEncoding];
    [usbCalls addObject:@{@"op":message[@"op"],@"args":message[@"args"],@"session":session}];
    return fakeOperation(@"usb",message[@"op"],message[@"args"],session);
}
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion { operationReply(@"usb",message[@"op"],[self handleMessage:message profile:profile],completion); }
- (void)permissionDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *))completion { inventory(@"usb", completion); }
@end
@implementation SerialBackend
+ (instancetype)sharedBackend { static SerialBackend *backend; static dispatch_once_t once; dispatch_once(&once,^{backend=[self new];}); return backend; }
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session completion:(void (^)(NSDictionary *))completion {
    [serialCalls addObject:@{@"op":operation,@"args":args,@"session":session}]; operationReply(@"serial",operation,fakeOperation(@"serial",operation,args,session),completion);
}
- (void)closeSession:(NSString *)session { [closedSerial addObject:session]; fakeOperation(@"serial",@"closeSession",@{},session); }
- (void)permissionDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *))completion { inventory(@"serial", completion); }
@end
@implementation HIDBackend
+ (instancetype)sharedBackend { static HIDBackend *backend; static dispatch_once_t once; dispatch_once(&once,^{backend=[self new];}); return backend; }
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session completion:(void (^)(NSDictionary *))completion {
    [hidCalls addObject:@{@"op":operation,@"args":args,@"session":session}]; operationReply(@"hid",operation,fakeOperation(@"hid",operation,args,session),completion);
}
- (void)closeSession:(NSString *)session { [closedHID addObject:session]; fakeOperation(@"hid",@"closeSession",@{},session); }
- (void)permissionDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *))completion { inventory(@"hid", completion); }
@end
static NSDictionary *call(NSString *op, NSString *profile, NSString *origin, NSString *instance) {
    NSMutableDictionary *message=[@{@"version":@1,@"op":op,@"session":@"document-session-1",@"origin":origin,@"args":@{}} mutableCopy];
    if (instance) message[@"instance"]=instance;
    __block NSDictionary *reply; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [router handleMessage:message profile:profile completion:^(NSDictionary *value){reply=value; dispatch_semaphore_signal(done);}];
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    return reply;
}
static NSDictionary *normalMessage(NSString *op, NSString *document, NSString *origin, id privateBrowsing, NSDictionary *args) {
    NSMutableDictionary *message=[@{@"version":@1,@"op":op,@"session":document,@"origin":origin,@"args":args,@"instance":@"epoch-1"} mutableCopy];
    if (privateBrowsing) message[@"privateBrowsing"]=privateBrowsing;
    return message;
}
static NSDictionary *send(NSDictionary *message, NSString *connection, NSString *profile) {
    __block NSDictionary *reply; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [router handleMessage:message profile:connection permissionProfile:profile completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);return reply;
}
static NSDictionary *manage(NSString *op, NSDictionary *args, NSString *profile, id privateBrowsing) {
    NSMutableDictionary *message=[@{@"version":@1,@"op":op,@"args":args} mutableCopy];if(privateBrowsing)message[@"privateBrowsing"]=privateBrowsing;
    __block NSDictionary *reply; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [router handlePermissionMessage:message permissionProfile:profile completion:^(NSDictionary *value){reply=value;dispatch_semaphore_signal(done);}];
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);return reply;
}
static NSDictionary *record(NSString *identifier, NSString *identity, BOOL durable) {
    return @{@"device":@{@"id":identifier,@"productName":@"Test device",@"opened":@NO},@"identity":identity,@"durable":@(durable)};
}
static NSString *opFor(NSString *kind, NSString *operation) { return [kind isEqual:@"usb"] ? operation : [NSString stringWithFormat:@"%@.%@",kind,operation]; }
static NSDictionary *deviceCall(NSString *kind, NSString *operation, NSString *document, NSString *connection, NSString *profile, NSString *origin, id privateBrowsing, NSString *device) {
    return send(normalMessage(opFor(kind,operation),document,origin,privateBrowsing,device?@{@"deviceId":device}:@{}),connection,profile);
}
static void persistenceTests(void) {
    router.eventHandler=nil;
    for (NSString *kind in @[@"usb",@"serial",@"hid"]) {
        NSString *list=[kind isEqual:@"serial"]?@"getPorts":@"getDevices";
        NSString *profile=@"saved-profile"; NSString *origin=@"https://devices.example";
        inventories[kind]=@[record(@"device-1",@"stable-device",YES)];
        CHECK([deviceCall(kind,@"enumerate",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,nil)[@"ok"] boolValue]);
        CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"device-1")[@"ok"] boolValue]);
        NSArray *saved=manage(@"permissions.list",@{},profile,@NO)[@"result"]; CHECK(saved.count==1);
        CHECK([saved[0][@"kind"] isEqual:kind] && [saved[0][@"origin"] isEqual:origin] && !saved[0][@"identity"] && !saved[0][@"profile"]);
        CHECK([saved[0][@"durable"] boolValue]);
        NSArray *restored=deviceCall(kind,list,@"saved-document-2",@"saved-connection-2",profile,origin,@NO,nil)[@"result"];
        CHECK(restored.count==1 && ![restored[0][@"opened"] boolValue]);
        // A backend lease may expire independently of the router capture.
        NSString *restoreKey=[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:@[@"saved-connection-2",@"saved-document-2"] options:0 error:nil] encoding:NSUTF8StringEncoding];
        [nativeGrants[[kind stringByAppendingString:restoreKey]] removeAllObjects];
        CHECK([deviceCall(kind,list,@"saved-document-2",@"saved-connection-2",profile,origin,@NO,nil)[@"result"] count]==1);
        NSMutableDictionary *stale=[normalMessage(opFor(kind,list),@"saved-document-2",origin,@NO,@{}) mutableCopy];stale[@"instance"]=@"expired-epoch";
        CHECK([send(stale,@"saved-connection-2",profile)[@"error"][@"name"] isEqual:@"InvalidStateError"]);
        CHECK([deviceCall(kind,list,@"other-origin-doc",@"other-origin-connection",profile,@"https://other.example",@NO,nil)[@"result"] count]==0);
        CHECK([deviceCall(kind,list,@"other-profile-doc",@"other-profile-connection",@"different-profile",origin,@NO,nil)[@"result"] count]==0);
        CHECK([deviceCall(kind,list,@"private-document",@"private-connection",profile,origin,@YES,nil)[@"result"] count]==0);
        CHECK([deviceCall(kind,@"grant",@"private-document",@"private-connection",profile,origin,@YES,@"device-1")[@"ok"] boolValue]);
        CHECK([deviceCall(kind,@"forget",@"private-document",@"private-connection",profile,origin,@YES,@"device-1")[@"ok"] boolValue]);
        CHECK([manage(@"permissions.list",@{},profile,@NO)[@"result"] count]==1);
        CHECK([deviceCall(kind,list,@"private-document",@"private-connection",profile,origin,@NO,nil)[@"error"][@"name"] isEqual:@"SecurityError"]);
        CHECK([deviceCall(kind,list,@"unknown-mode-doc",@"unknown-mode-connection",profile,origin,nil,nil)[@"result"] count]==0);
        CHECK([manage(@"permissions.list",@{},profile,@YES)[@"error"][@"name"] isEqual:@"SecurityError"]);
        CHECK([manage(@"permissions.list",@{},profile,nil)[@"error"][@"name"] isEqual:@"SecurityError"]);
        // Persistent serial identity survives a new attachment; no handle opens.
        inventories[kind]=@[record(@"device-2",@"stable-device",YES)];
        CHECK([deviceCall(kind,list,@"reattached-document",@"reattached-connection",profile,origin,@NO,nil)[@"result"] count]==1);
        inventories[kind]=@[];
        CHECK([send(normalMessage(@"heartbeat",@"saved-document-1",origin,@NO,@{}),@"saved-connection-1",profile)[@"ok"] boolValue]);
        CHECK([deviceCall(kind,list,@"detached-document",@"detached-connection",profile,origin,@NO,nil)[@"result"] count]==0);
        // An old object can forget after unplug, revoking grants in all documents.
        CHECK([deviceCall(kind,@"forget",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"device-1")[@"ok"] boolValue]);
        CHECK([manage(@"permissions.list",@{},profile,@NO)[@"result"] count]==0);
        inventories[kind]=@[record(@"device-2",@"stable-device",YES)];
        CHECK([deviceCall(kind,list,@"saved-document-2",@"saved-connection-2",profile,origin,@NO,nil)[@"result"] count]==0);
        CHECK([deviceCall(kind,list,@"reattached-document",@"reattached-connection",profile,origin,@NO,nil)[@"result"] count]==0);
        // Attachment-only identities survive reload, but replacement attachments do not match.
        inventories[kind]=@[record(@"attached-1",@"boot-1-attachment-1",NO)];
        CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"attached-1")[@"ok"] boolValue]);
        CHECK([deviceCall(kind,list,@"saved-document-2",@"saved-connection-2",profile,origin,@NO,nil)[@"result"] count]==1);
        inventories[kind]=@[record(@"attached-2",@"boot-1-attachment-2",NO)];
        CHECK([deviceCall(kind,list,@"replacement-document",@"replacement-connection",profile,origin,@NO,nil)[@"result"] count]==0);
        CHECK([manage(@"permissions.clear",@{},profile,@NO)[@"ok"] boolValue]);
        // Duplicate hardware identities must never automatically receive permission.
        inventories[kind]=@[record(@"device-1",@"stable-device",YES)];
        CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"device-1")[@"ok"] boolValue]);
        inventories[kind]=@[record(@"device-1",@"stable-device",YES),record(@"device-2",@"stable-device",YES)];
        CHECK([deviceCall(kind,list,@"duplicate-document",@"duplicate-connection",profile,origin,@NO,nil)[@"result"] count]==0);
        CHECK([manage(@"permissions.clear",@{},profile,@NO)[@"ok"] boolValue]);
        CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"device-1")[@"ok"] boolValue]);
        CHECK([manage(@"permissions.list",@{},profile,@NO)[@"result"] count]==0);
        // Revoke on another connection fences an inventory or a native grant already in flight.
        inventories[kind]=@[record(@"device-1",@"stable-device",YES)];
        CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"device-1")[@"ok"] boolValue]);
        for (NSNumber *duringGrant in @[@NO,@YES]) {
            held=dispatch_semaphore_create(0);dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSDictionary *raceReply;
            if (duringGrant.boolValue) holdGrant=kind; else holdInventory=kind;
            NSString *document=duringGrant.boolValue?@"grant-race-document":@"inventory-race-document";
            [router handleMessage:normalMessage(opFor(kind,list),document,origin,@NO,@{}) profile:document permissionProfile:profile completion:^(NSDictionary *value){raceReply=value;dispatch_semaphore_signal(done);}];
            CHECK(dispatch_semaphore_wait(held,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
            CHECK([manage(@"permissions.clear",@{},profile,@NO)[@"ok"] boolValue]);
            if (duringGrant.boolValue) { holdGrant=nil;pendingGrant(pendingGrantResult);pendingGrant=nil;pendingGrantResult=nil; }
            else { holdInventory=nil;pendingInventory(inventories[kind]);pendingInventory=nil; }
            CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
            CHECK([raceReply[@"error"][@"name"] isEqual:@"SecurityError"]);
            CHECK([deviceCall(kind,list,document,document,profile,origin,@NO,nil)[@"result"] count]==0);
            CHECK([manage(@"permissions.list",@{},profile,@NO)[@"result"] count]==0);
            CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"device-1")[@"ok"] boolValue]);
        }
        NSArray *final=manage(@"permissions.list",@{},profile,@NO)[@"result"];
        CHECK([manage(@"permissions.revoke",@{@"id":final[0][@"id"]},@"wrong-profile",@NO)[@"ok"] boolValue]);
        CHECK([manage(@"permissions.list",@{},profile,@NO)[@"result"] count]==1);
        CHECK([manage(@"permissions.revoke",@{@"id":final[0][@"id"]},profile,@NO)[@"ok"] boolValue]);
        CHECK([manage(@"permissions.list",@{},profile,@NO)[@"result"] count]==0);
        // Fresh grants that fail native validation are never remembered.
        CHECK([deviceCall(kind,@"grant",@"saved-document-1",@"saved-connection-1",profile,origin,@NO,@"missing")[@"error"][@"name"] isEqual:@"NotFoundError"]);
    }
}
int main(void) { @autoreleasepool {
    router=[[DeviceBridgeBackend alloc] initWithPermissionStore:[[DevicePermissionStore alloc] initWithURL:nil]];
    inventories=[NSMutableDictionary dictionary];nativeGrants=[NSMutableDictionary dictionary];usbCalls=[NSMutableArray array];
    serialCalls=[NSMutableArray array]; hidCalls=[NSMutableArray array]; closedSerial=[NSMutableArray array]; closedHID=[NSMutableArray array];
    CHECK([call(@"serial.enumerate",@"profile-a",@"http://remote.example",nil)[@"error"][@"name"] isEqual:@"SecurityError"]);
    CHECK(serialCalls.count==0);
    CHECK([call(@"serial.enumerate",@"profile-a",@"https://example.org",nil)[@"ok"] boolValue]);
    CHECK([serialCalls.lastObject[@"op"] isEqual:@"enumerate"]);
    NSString *key=serialCalls.lastObject[@"session"];
    CHECK([call(@"serial.open",@"profile-a",@"https://example.org",@"wrong")[@"error"][@"name"] isEqual:@"InvalidStateError"]);
    CHECK(serialCalls.count==1);
    CHECK([call(@"hid.enumerate",@"profile-a",@"https://other.example",nil)[@"error"][@"name"] isEqual:@"SecurityError"]);
    CHECK(hidCalls.count==0);
    CHECK([call(@"hid.enumerate",@"profile-a",@"https://example.org",nil)[@"ok"] boolValue]);
    CHECK([hidCalls.lastObject[@"session"] isEqual:key]);
    CHECK([call(@"serial.open",@"profile-b",@"https://example.org",@"epoch-1")[@"error"][@"name"] isEqual:@"InvalidStateError"]);
    CHECK([call(@"serial.enumerate",@"profile-b",@"https://example.org",nil)[@"ok"] boolValue]);
    CHECK(![serialCalls.lastObject[@"session"] isEqual:key]);
    __block NSDictionary *seen; dispatch_semaphore_t event=dispatch_semaphore_create(0);
    router.eventHandler=^(NSString *profile,NSString *session,NSDictionary *value){
        seen=@{@"profile":profile,@"session":session,@"event":value}; dispatch_semaphore_signal(event);
    };
    [SerialBackend sharedBackend].eventHandler(@"unknown",@{@"event":@"serial.data"});
    [SerialBackend sharedBackend].eventHandler(key,@{@"event":@"serial.data",@"deviceId":@"port",@"data":@"AQ=="});
    CHECK(dispatch_semaphore_wait(event,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0);
    CHECK([seen[@"profile"] isEqual:@"profile-a"] && [seen[@"session"] isEqual:@"document-session-1"]);
    CHECK([seen[@"event"][@"data"] isEqual:@"AQ=="]);
    CHECK([call(@"closeSession",@"profile-a",@"https://example.org",@"epoch-1")[@"ok"] boolValue]);
    CHECK([closedSerial containsObject:key] && [closedHID containsObject:key]);
    [HIDBackend sharedBackend].eventHandler(key,@{@"event":@"hid.inputreport"});
    CHECK(dispatch_semaphore_wait(event,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC))!=0);
    CHECK([call(@"hid.open",@"profile-a",@"https://example.org",@"epoch-1")[@"error"][@"name"] isEqual:@"InvalidStateError"]);
    CHECK([call(@"serial.getPorts",@"profile-b",@"https://example.org",@"epoch-1")[@"ok"] boolValue]);
    persistenceTests();
    printf("DeviceBridgeBackend: %lu assertions passed (fake hardware)\n",(unsigned long)assertions);
} return 0; }
