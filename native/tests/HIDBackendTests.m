#import "../HIDBackend.h"
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <stdlib.h>

// These symbols replace every HID/registry call used by HIDBackend. This test
// never enumerates, opens, or writes to a physical device.
@interface FakeHID : NSObject
@property(nonatomic) NSUInteger service;
@property(nonatomic) NSDictionary *properties;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic, copy) dispatch_block_t cancel;
@property(nonatomic) IOHIDReportCallback input;
@property(nonatomic) void *inputContext;
@property(nonatomic) IOHIDCallback removed;
@property(nonatomic) void *removedContext;
@property(nonatomic) BOOL opened;
@end
@implementation FakeHID
@end
static NSMutableDictionary<NSNumber *, FakeHID *> *inventory;
static NSMutableDictionary<NSNumber *, FakeHID *> *activeDevices;
static NSUInteger openCalls, closeCalls, setCalls, getCalls;
static BOOL pauseReports;
static NSData *lastReport;
static NSUInteger lastReportID;
static IOHIDReportType lastType;
static CFTimeInterval lastTimeout;
static FakeHID *Device(IOHIDDeviceRef device) { return (__bridge FakeHID *)device; }
IOHIDManagerRef IOHIDManagerCreate(CFAllocatorRef allocator, IOOptionBits options) {
    (void)allocator;
    if (!(options & kIOHIDManagerOptionIndependentDevices)) abort();
    return (IOHIDManagerRef)CFBridgingRetain([[FakeHID alloc] init]);
}
void IOHIDManagerSetDeviceMatching(IOHIDManagerRef manager, CFDictionaryRef matching) { (void)manager; (void)matching; }
void IOHIDManagerSetDispatchQueue(IOHIDManagerRef manager, dispatch_queue_t queue) { ((__bridge FakeHID *)manager).queue = queue; }
void IOHIDManagerActivate(IOHIDManagerRef manager) { (void)manager; }
void IOHIDManagerSetCancelHandler(IOHIDManagerRef manager, dispatch_block_t handler) { ((__bridge FakeHID *)manager).cancel = handler; }
void IOHIDManagerCancel(IOHIDManagerRef manager) {
    FakeHID *fake = (__bridge FakeHID *)manager;
    dispatch_async(fake.queue, ^{ if (fake.cancel) fake.cancel(); });
}
CFSetRef IOHIDManagerCopyDevices(IOHIDManagerRef manager) { (void)manager; return (CFSetRef)CFBridgingRetain([NSSet setWithArray:inventory.allValues]); }
io_service_t IOHIDDeviceGetService(IOHIDDeviceRef device) { return (io_service_t)Device(device).service; }
kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *identifier) { *identifier = entry; return kIOReturnSuccess; }
CFTypeRef IOHIDDeviceGetProperty(IOHIDDeviceRef device, CFStringRef key) { return (__bridge CFTypeRef)Device(device).properties[(__bridge NSString *)key]; }
IOHIDDeviceRef IOHIDDeviceCreate(CFAllocatorRef allocator, io_service_t service) {
    (void)allocator;
    FakeHID *source = inventory[@(service)];
    if (!source) return NULL;
    FakeHID *fake = [[FakeHID alloc] init]; fake.service = service; fake.properties = source.properties;
    return (IOHIDDeviceRef)CFBridgingRetain(fake);
}
IOReturn IOHIDDeviceOpen(IOHIDDeviceRef device, IOOptionBits options) {
    if (options != kIOHIDOptionsTypeSeizeDevice) abort();
    openCalls++;
    FakeHID *fake = Device(device); fake.opened = YES; activeDevices[@(fake.service)] = fake; return kIOReturnSuccess;
}
IOReturn IOHIDDeviceClose(IOHIDDeviceRef device, IOOptionBits options) {
    (void)options; closeCalls++;
    FakeHID *fake = Device(device); fake.opened = NO; [activeDevices removeObjectForKey:@(fake.service)]; return kIOReturnSuccess;
}
void IOHIDDeviceRegisterInputReportCallback(IOHIDDeviceRef device, uint8_t *report, CFIndex length, IOHIDReportCallback callback, void *context) {
    (void)report; (void)length; Device(device).input = callback; Device(device).inputContext = context;
}
void IOHIDDeviceRegisterRemovalCallback(IOHIDDeviceRef device, IOHIDCallback callback, void *context) { Device(device).removed = callback; Device(device).removedContext = context; }
void IOHIDDeviceSetDispatchQueue(IOHIDDeviceRef device, dispatch_queue_t queue) { Device(device).queue = queue; }
void IOHIDDeviceSetCancelHandler(IOHIDDeviceRef device, dispatch_block_t handler) { Device(device).cancel = handler; }
void IOHIDDeviceActivate(IOHIDDeviceRef device) { (void)device; }
void IOHIDDeviceCancel(IOHIDDeviceRef device) {
    FakeHID *fake = Device(device);
    dispatch_async(fake.queue, ^{ if (fake.cancel) { dispatch_block_t block = fake.cancel; fake.cancel = nil; block(); } });
}
IOReturn IOHIDDeviceSetReportWithCallback(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                                        const uint8_t *report, CFIndex length, CFTimeInterval timeout, IOHIDReportCallback callback, void *context) {
    setCalls++; lastReport = [NSData dataWithBytes:report length:(NSUInteger)length]; lastReportID = (NSUInteger)reportID; lastType = type; lastTimeout = timeout;
    FakeHID *fake = Device(device);
    if (!pauseReports) dispatch_async(fake.queue, ^{ callback(context, kIOReturnSuccess, (__bridge void *)fake, type, (uint32_t)reportID, (uint8_t *)report, length); });
    return kIOReturnSuccess;
}
IOReturn IOHIDDeviceGetReportWithCallback(IOHIDDeviceRef device, IOHIDReportType type, CFIndex reportID,
                                        uint8_t *report, CFIndex *length, CFTimeInterval timeout, IOHIDReportCallback callback, void *context) {
    getCalls++; lastReportID = (NSUInteger)reportID; lastTimeout = timeout;
    FakeHID *fake = Device(device);
    if (!pauseReports) dispatch_async(fake.queue, ^{
        for (CFIndex i = 0; i < *length; i++) report[i] = (uint8_t)(0x10 + i);
        if (reportID) report[0] = (uint8_t)reportID;
        callback(context, kIOReturnSuccess, (__bridge void *)fake, type, (uint32_t)reportID, report, *length);
    });
    return kIOReturnSuccess;
}

static unsigned checks;
static void Check(BOOL condition, NSString *message) {
    checks++; if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSData *Hex(NSString *text) {
    NSMutableData *data = [NSMutableData data];
    for (NSString *part in [text componentsSeparatedByString:@" "]) { uint8_t value = (uint8_t)strtoul(part.UTF8String, NULL, 16); [data appendBytes:&value length:1]; }
    return data;
}
static NSDictionary *Call(HIDBackend *backend, NSString *op, NSString *session, NSDictionary *args) {
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSDictionary *response;
    [backend handleOperation:op args:args session:session completion:^(NSDictionary *r) { response = r; dispatch_semaphore_signal(sem); }];
    Check(dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0, [@"request completed: " stringByAppendingString:op]);
    return response;
}
static void Add(NSUInteger service, NSUInteger vendor, NSUInteger product, NSString *descriptor) {
    FakeHID *fake = [[FakeHID alloc] init]; fake.service = service;
    fake.properties = @{@kIOHIDVendorIDKey: @(vendor), @kIOHIDProductIDKey: @(product), @kIOHIDProductKey: @"Fake Prime",
                        @kIOHIDReportDescriptorKey: Hex(descriptor)};
    inventory[@(service)] = fake;
}
static void Input(FakeHID *fake, unsigned reportID, NSString *hex) {
    NSData *data = Hex(hex);
    dispatch_sync(fake.queue, ^{ if (fake.input) fake.input(fake.inputContext, kIOReturnSuccess, (__bridge void *)fake, kIOHIDReportTypeInput, reportID, (uint8_t *)data.bytes, (CFIndex)data.length); });
}
int main(void) { @autoreleasepool {
    inventory = [NSMutableDictionary dictionary]; activeDevices = [NSMutableDictionary dictionary];
    NSString *vendorDescriptor = @"06 00 ff 09 01 a1 01 85 03 15 00 26 ff 00 75 08 95 04 09 01 81 02 09 01 91 02 09 01 b1 02 c0";
    NSString *keyboard = @"05 01 09 06 a1 01 75 08 95 01 09 06 81 02 c0";
    Add(1, 0x03f0, 0x2441, vendorDescriptor); Add(2, 0x03f0, 0x1234, keyboard);
    Add(3, 0x1050, 0x0407, vendorDescriptor);
    HIDBackend *backend = [[HIDBackend alloc] init];
    NSMutableArray *events = [NSMutableArray array];
    backend.eventHandler = ^(NSString *session, NSDictionary *event) { @synchronized(events) { [events addObject:@{@"session": session, @"event": event}]; } };
    NSDictionary *response = Call(backend, @"enumerate", @"a", @{});
    Check([response[@"ok"] boolValue] && [response[@"result"] count] == 1, @"enumeration hides protected usage and token vendor");
    Check(openCalls == 0, @"enumeration opens no devices");
    NSString *identifier = response[@"result"][0][@"id"];
    Check([identifier hasPrefix:@"hid:"] && ![identifier containsString:@"/dev"], @"opaque device ID");
    NSDictionary *device = @{@"deviceId": identifier};
    Check([Call(backend, @"getDevices", @"a", @{})[@"result"] count] == 0, @"ungranted devices hidden");
    Check([Call(backend, @"open", @"a", device)[@"error"][@"name"] isEqual:@"SecurityError"], @"ungranted open denied");
    Check(![Call(backend, @"grant", @"a", @{@"deviceId": @"/dev/keyboard"})[@"ok"] boolValue], @"invented path denied");
    Check([Call(backend, @"grant", @"a", device)[@"ok"] boolValue], @"explicit grant accepted");
    Check([Call(backend, @"getDevices", @"a", @{})[@"result"] count] == 1, @"granted device visible");
    Check([Call(backend, @"getDevices", @"b", @{})[@"result"] count] == 0, @"grant isolated by session");
    NSDictionary *originalProperties = inventory[@1].properties;
    NSMutableDictionary *changed = [originalProperties mutableCopy]; changed[@kIOHIDReportDescriptorKey] = Hex(keyboard); inventory[@1].properties = changed;
    Check([Call(backend, @"open", @"a", device)[@"error"][@"name"] isEqual:@"SecurityError"], @"descriptor changes rechecked before native open");
    changed = [originalProperties mutableCopy]; changed[@kIOHIDPrimaryUsagePageKey] = @1; changed[@kIOHIDPrimaryUsageKey] = @2; inventory[@1].properties = changed;
    Check([Call(backend, @"open", @"a", device)[@"error"][@"name"] isEqual:@"SecurityError"], @"protected primary usage rechecked before native open");
    inventory[@1].properties = originalProperties;
    Check(openCalls == 0, @"changed protected devices never opened");
    Check([Call(backend, @"open", @"a", device)[@"result"][@"opened"] isEqual:@YES], @"open snapshot uses boolean");
    Check(openCalls == 1, @"native open once");
    Check([Call(backend, @"open", @"a", device)[@"ok"] boolValue] && openCalls == 1, @"open idempotent in owner session");
    Call(backend, @"grant", @"b", device);
    Check([Call(backend, @"open", @"b", device)[@"error"][@"name"] isEqual:@"InvalidStateError"], @"exclusive ownership across grants");
    Call(backend, @"close", @"b", device);
    Check(closeCalls == 0, @"other session cannot close owner device");
    NSDictionary *report = @{@"deviceId": identifier, @"reportId": @3, @"data": @"AQIDBA=="};
    Check([Call(backend, @"sendReport", @"b", report)[@"error"][@"name"] isEqual:@"InvalidStateError"], @"cross-session output denied");
    Check([Call(backend, @"sendReport", @"a", report)[@"ok"] boolValue], @"output report completed");
    Check([lastReport isEqual:Hex(@"03 01 02 03 04")] && lastReportID == 3, @"IOKit output includes numbered prefix");
    Check(lastType == kIOHIDReportTypeOutput && lastTimeout == 5000, @"output type and bounded API timeout");
    Check([Call(backend, @"sendFeatureReport", @"a", report)[@"ok"] boolValue] && lastType == kIOHIDReportTypeFeature, @"feature output distinct type");
    response = Call(backend, @"receiveFeatureReport", @"a", @{@"deviceId": identifier, @"reportId": @3});
    Check([response[@"ok"] boolValue] && [response[@"result"][@"data"] isEqual:@"AxESExQ="], @"feature result includes report ID");
    Check(getCalls == 1 && setCalls == 2, @"report operations reached driver exactly once");
    Check(![Call(backend, @"sendReport", @"a", @{@"deviceId": identifier, @"reportId": @4, @"data": @"AQ=="})[@"ok"] boolValue], @"undeclared report ID denied");
    Check(![Call(backend, @"sendReport", @"a", @{@"deviceId": identifier, @"reportId": @YES, @"data": @"AQ=="})[@"ok"] boolValue], @"boolean report ID denied");
    Check(![Call(backend, @"sendReport", @"a", @{@"deviceId": identifier, @"reportId": @3, @"data": @"AQIDBAU="})[@"ok"] boolValue], @"oversized output denied");
    Check(![Call(backend, @"sendReport", @"a", @{@"deviceId": identifier, @"reportId": @3, @"data": @"!invalid!"})[@"ok"] boolValue], @"malformed base64 denied");
    Check(setCalls == 2, @"invalid writes never reached driver");
    FakeHID *fake = activeDevices[@1];
    Input(fake, 3, @"03 20 21 22 23");
    Check(events.count == 1 && [events[0][@"session"] isEqual:@"a"], @"input delivered only to owner");
    Check([events[0][@"event"][@"data"] isEqual:@"ICEiIw=="] && [events[0][@"event"][@"reportId"] intValue] == 3, @"input removes numbered prefix");
    Input(fake, 3, @"07 20 21"); Input(fake, 4, @"04 20 21"); Input(fake, 3, @"03 00 01 02 03 04");
    Check(events.count == 1, @"unknown IDs, wrong prefixes and oversized inputs suppressed");
    // An outstanding write must be aborted without freeing IOKit buffers until
    // cancellation. The serial queue remains free to process close.
    pauseReports = YES;
    dispatch_semaphore_t pendingDone = dispatch_semaphore_create(0);
    __block NSDictionary *pendingResponse;
    [backend handleOperation:@"sendReport" args:report session:@"a" completion:^(NSDictionary *r) { pendingResponse = r; dispatch_semaphore_signal(pendingDone); }];
    // Input remains asynchronous while a report completion is delayed.
    Input(fake, 3, @"03 30 31 32 33");
    Check(events.count == 2 && [events.lastObject[@"event"][@"data"] isEqual:@"MDEyMw=="], @"pending write does not block input callbacks");
    Call(backend, @"close", @"a", device);
    Check(dispatch_semaphore_wait(pendingDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0, @"close resolves pending asynchronous report");
    Check([pendingResponse[@"error"][@"name"] isEqual:@"AbortError"], @"pending report aborted on close");
    Check(closeCalls == 1, @"driver closed once"); pauseReports = NO;
    Check([Call(backend, @"open", @"a", device)[@"ok"] boolValue], @"reopen after cancellation uses fresh HID handle");
    Call(backend, @"forget", @"a", device);
    Check(closeCalls == 2 && [Call(backend, @"getDevices", @"a", @{})[@"result"] count] == 0, @"forget closes and revokes");
    Check([Call(backend, @"getDevices", @"b", @{})[@"result"] count] == 1, @"forget does not revoke another document");
    [backend closeSession:@"b"];
    Check([Call(backend, @"getDevices", @"b", @{})[@"result"] count] == 0, @"session cleanup revokes grant");
    Call(backend, @"grant", @"a", device); Call(backend, @"open", @"a", device);
    [inventory removeObjectForKey:@1];
    Call(backend, @"getDevices", @"a", @{});
    Check([events.lastObject[@"event"][@"event"] isEqual:@"hid.disconnect"], @"removal delivers disconnect");
    Check(closeCalls == 3, @"removal closes native handle");
    Add(1, 0x03f0, 0x2441, vendorDescriptor);
    Check([Call(backend, @"getDevices", @"a", @{})[@"result"] count] == 0, @"replug never silently renews old grant");
    response = Call(backend, @"enumerate", @"a", @{});
    Check(![response[@"result"][0][@"id"] isEqual:identifier], @"replug gets new opaque ID");
    // Missing driver callback triggers the bounded guard, revokes the stale
    // grant, emits disconnect and permits a fresh chooser grant afterwards.
    identifier = response[@"result"][0][@"id"];
    device = @{@"deviceId": identifier};
    Call(backend, @"grant", @"a", device); Call(backend, @"open", @"a", device);
    pauseReports = YES;
    response = Call(backend, @"sendReport", @"a", @{@"deviceId": identifier, @"reportId": @3, @"data": @"AQ=="});
    Check([response[@"error"][@"name"] isEqual:@"TimeoutError"], @"missing driver callback bounded by guard");
    Check([Call(backend, @"getDevices", @"a", @{})[@"result"] count] == 0, @"timeout revokes grant");
    Check([events.lastObject[@"event"][@"event"] isEqual:@"hid.disconnect"], @"timeout clears page open state via disconnect");
    Check(closeCalls == 4, @"timeout closes native handle");
    pauseReports = NO;
    NSLog(@"HID backend tests: %u assertions passed", checks);
} return 0; }
