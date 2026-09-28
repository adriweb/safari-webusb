#import "../DeviceBridgeBackend.h"
#import "../USBBackend.h"
#import "../SerialBackend.h"
#import "../HIDBackend.h"
static NSUInteger assertions;
static NSMutableArray *serialCalls, *hidCalls, *closedSerial, *closedHID;
#define CHECK(...) do { assertions++; if (!(__VA_ARGS__)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#__VA_ARGS__); exit(1); } } while(0)
@implementation USBBackend
+ (instancetype)sharedBackend { static USBBackend *backend; static dispatch_once_t once; dispatch_once(&once,^{backend=[self new];}); return backend; }
- (NSString *)instance { return @"epoch-1"; }
- (NSDictionary *)handleMessage:(id)message profile:(NSString *)profile { (void)message; (void)profile; return @{@"ok":@YES,@"instance":self.instance,@"result":NSNull.null}; }
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion { completion([self handleMessage:message profile:profile]); }
@end
@implementation SerialBackend
+ (instancetype)sharedBackend { static SerialBackend *backend; static dispatch_once_t once; dispatch_once(&once,^{backend=[self new];}); return backend; }
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session completion:(void (^)(NSDictionary *))completion {
    [serialCalls addObject:@{@"op":operation,@"args":args,@"session":session}]; completion(@{@"ok":@YES,@"result":@[]});
}
- (void)closeSession:(NSString *)session { [closedSerial addObject:session]; }
@end
@implementation HIDBackend
+ (instancetype)sharedBackend { static HIDBackend *backend; static dispatch_once_t once; dispatch_once(&once,^{backend=[self new];}); return backend; }
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session completion:(void (^)(NSDictionary *))completion {
    [hidCalls addObject:@{@"op":operation,@"args":args,@"session":session}]; completion(@{@"ok":@YES,@"result":@[]});
}
- (void)closeSession:(NSString *)session { [closedHID addObject:session]; }
@end
static NSDictionary *call(NSString *op, NSString *profile, NSString *origin, NSString *instance) {
    NSMutableDictionary *message=[@{@"version":@1,@"op":op,@"session":@"document-session-1",@"origin":origin,@"args":@{}} mutableCopy];
    if (instance) message[@"instance"]=instance;
    __block NSDictionary *reply; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    [[DeviceBridgeBackend sharedBackend] handleMessage:message profile:profile completion:^(NSDictionary *value){reply=value; dispatch_semaphore_signal(done);}];
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0);
    return reply;
}
int main(void) { @autoreleasepool {
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
    [DeviceBridgeBackend sharedBackend].eventHandler=^(NSString *profile,NSString *session,NSDictionary *value){
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
    printf("DeviceBridgeBackend: %lu assertions passed (fake hardware)\n",(unsigned long)assertions);
} return 0; }
