#import "HIDBackend.h"
#import "PermissionIdentity.h"
#import "HIDReportDescriptor.h"
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <math.h>

static const NSUInteger HIDMaximumTransfer = 1024 * 1024;
static const NSUInteger HIDMaximumDevices = 256;
static const NSUInteger HIDMaximumPendingReports = 16;
static const NSTimeInterval HIDReportTimeout = 5;
#ifndef HID_REPORT_GUARD_SECONDS
#define HID_REPORT_GUARD_SECONDS 6
#endif

static NSDictionary *HIDFailure(NSString *name, NSString *message) {
    return @{@"ok": @NO, @"error": @{@"name": name, @"message": message}};
}
static NSDictionary *HIDSuccess(id result) { return @{@"ok": @YES, @"result": result ?: NSNull.null}; }
static NSDictionary *HIDIOFailure(IOReturn result, NSString *action) {
    NSString *name = @"NetworkError";
    if (result == kIOReturnNotPermitted || result == kIOReturnNotPrivileged) name = @"NotAllowedError";
    else if (result == kIOReturnExclusiveAccess || result == kIOReturnBusy) name = @"InvalidStateError";
    else if (result == kIOReturnNoDevice || result == kIOReturnNotAttached) name = @"NotFoundError";
    else if (result == kIOReturnTimeout) name = @"TimeoutError";
    else if (result == kIOReturnUnsupported) name = @"NotSupportedError";
    return HIDFailure(name, [NSString stringWithFormat:@"%@: %@ (0x%08x).", action,
                              result == kIOReturnNotPermitted ? @"macOS denied HID device access" : @"HID operation failed", result]);
}
static BOOL HIDInteger(id value, NSUInteger maximum, NSUInteger *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0 || number > maximum || floor(number) != number) return NO;
    if (result) *result = (NSUInteger)number;
    return YES;
}
static id HIDProperty(IOHIDDeviceRef device, CFStringRef name) {
    return (__bridge id)IOHIDDeviceGetProperty(device, name);
}

@class HIDOpenDevice, HIDPendingReport;
@interface HIDDeviceRecord : NSObject
@property(nonatomic) IOHIDDeviceRef device;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) uint64_t registryID;
@property(nonatomic) NSDictionary *descriptor;
@property(nonatomic) NSNumber *vendor;
@property(nonatomic) NSNumber *product;
@property(nonatomic) NSString *productName;
@property(nonatomic) NSString *permissionIdentity;
@property(nonatomic) BOOL permissionDurable;
@end
@implementation HIDDeviceRecord
- (void)dealloc { if (_device) CFRelease(_device); }
@end

@interface HIDOpenDevice : NSObject
@property(nonatomic, weak) HIDBackend *backend;
@property(nonatomic) HIDDeviceRecord *record;
@property(nonatomic, copy) NSString *session;
@property(nonatomic) IOHIDDeviceRef device;
@property(nonatomic) NSMutableData *inputBuffer;
@property(nonatomic) NSMutableDictionary<NSString *, HIDPendingReport *> *pending;
@property(nonatomic) BOOL closing;
@end
@implementation HIDOpenDevice
@end

@interface HIDPendingReport : NSObject {
@public CFIndex reportLength;
}
@property(nonatomic, weak) HIDOpenDevice *owner;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic) NSMutableData *buffer;
@property(nonatomic) BOOL receiving;
@property(nonatomic) NSUInteger reportID;
@property(nonatomic, copy) void (^completion)(NSDictionary *response);
@end
@implementation HIDPendingReport
@end

@interface HIDBackend ()
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) IOHIDManagerRef manager;
@property(nonatomic) NSMutableDictionary<NSString *, HIDDeviceRecord *> *devices;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *grants;
@property(nonatomic) NSMutableDictionary<NSString *, HIDOpenDevice *> *opened;
- (void)refreshDevices;
- (void)removeDevice:(NSString *)identifier;
- (void)finishReport:(HIDPendingReport *)pending result:(IOReturn)result bytes:(uint8_t *)bytes length:(CFIndex)length;
- (void)inputReport:(HIDOpenDevice *)opened result:(IOReturn)result type:(IOHIDReportType)type
          reportID:(uint32_t)reportID bytes:(uint8_t *)bytes length:(CFIndex)length;
@end

static void HIDInput(void *context, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)sender;
    HIDOpenDevice *opened = (__bridge HIDOpenDevice *)context;
    [opened.backend inputReport:opened result:result type:type reportID:reportID bytes:report length:reportLength];
}
static void HIDRemoved(void *context, IOReturn result, void *sender) {
    (void)result; (void)sender;
    HIDOpenDevice *opened = (__bridge HIDOpenDevice *)context;
    [opened.backend removeDevice:opened.record.identifier];
}
static void HIDReportComplete(void *context, IOReturn result, void *sender, IOHIDReportType type,
                              uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    (void)sender; (void)type; (void)reportID;
    HIDPendingReport *pending = (__bridge HIDPendingReport *)context;
    [pending.owner.backend finishReport:pending result:result bytes:report length:reportLength];
}

@implementation HIDBackend
+ (instancetype)sharedBackend {
    static HIDBackend *backend; static dispatch_once_t once;
    dispatch_once(&once, ^{ backend = [[self alloc] init]; });
    return backend;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("org.webusb.safari.native.hid", DISPATCH_QUEUE_SERIAL);
        _devices = [NSMutableDictionary dictionary]; _grants = [NSMutableDictionary dictionary]; _opened = [NSMutableDictionary dictionary];
        // IndependentDevices prevents the manager from opening keyboards and
        // mice. Only an explicitly granted, descriptor-validated device opens.
        _manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDManagerOptionIndependentDevices |
                                     kIOHIDManagerOptionDoNotLoadProperties | kIOHIDManagerOptionDoNotSaveProperties);
        if (_manager) {
            IOHIDManagerSetDeviceMatching(_manager, NULL);
            IOHIDManagerSetDispatchQueue(_manager, _queue);
            IOHIDManagerRef manager = _manager;
            IOHIDManagerSetCancelHandler(manager, ^{ CFRelease(manager); });
            IOHIDManagerActivate(_manager);
        }
    }
    return self;
}
- (void)dealloc {
    if (_manager) {
        IOHIDManagerCancel(_manager);
    }
}
- (NSDictionary *)snapshot:(HIDDeviceRecord *)record session:(NSString *)session {
    HIDOpenDevice *opened = self.opened[record.identifier];
    return @{@"id": record.identifier, @"vendorId": record.vendor, @"productId": record.product,
             @"productName": record.productName, @"opened": @(!opened.closing && [opened.session isEqual:session]),
             @"collections": record.descriptor[@"collections"]};
}
- (void)emit:(NSDictionary *)event session:(NSString *)session {
    void (^handler)(NSString *, NSDictionary *) = self.eventHandler;
    if (handler) handler(session, event);
}
- (void)closeDevice:(HIDOpenDevice *)opened {
    if (!opened || opened.closing) return;
    opened.closing = YES;
    [self.opened removeObjectForKey:opened.record.identifier];
    // Cancel handler retains both buffers and callback contexts until IOKit
    // confirms all callbacks have stopped. Closing never frees in-flight data.
    IOHIDDeviceClose(opened.device, kIOHIDOptionsTypeNone);
    IOHIDDeviceCancel(opened.device);
}
- (void)removeDevice:(NSString *)identifier {
    HIDDeviceRecord *record = self.devices[identifier];
    if (!record) return;
    [self closeDevice:self.opened[identifier]];
    [self.devices removeObjectForKey:identifier];
    for (NSString *session in self.grants) {
        if ([self.grants[session] containsObject:identifier]) {
            [self.grants[session] removeObject:identifier];
            [self emit:@{@"event": @"hid.disconnect", @"deviceId": identifier} session:session];
        }
    }
}
- (void)refreshDevices {
    if (!self.manager) return;
    CFSetRef set = IOHIDManagerCopyDevices(self.manager);
    NSSet *current = CFBridgingRelease(set);
    NSMutableDictionary *previous = [NSMutableDictionary dictionary];
    for (HIDDeviceRecord *record in self.devices.allValues) {
        id attachmentKey = record.registryID ? @(record.registryID) : [NSValue valueWithPointer:record.device];
        previous[attachmentKey] = record;
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (id object in current) {
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)object;
        uint64_t registryID = 0;
        if (IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID) != kIOReturnSuccess) continue;
        id attachmentKey = registryID ? @(registryID) : [NSValue valueWithPointer:device];
        HIDDeviceRecord *record = previous[attachmentKey];
        if (record) { [seen addObject:record.identifier]; continue; }
        if (self.devices.count >= HIDMaximumDevices) continue;
        NSUInteger vendor = 0, product = 0;
        if (!HIDInteger(HIDProperty(device, CFSTR(kIOHIDVendorIDKey)), 65535, &vendor) ||
            !HIDInteger(HIDProperty(device, CFSTR(kIOHIDProductIDKey)), 65535, &product) || HIDDeviceIsBlocked((uint16_t)vendor, (uint16_t)product)) continue;
        // Some drivers publish primary usages outside their report descriptor.
        NSUInteger page = 0, usage = 0;
        if (HIDInteger(HIDProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey)), 65535, &page) &&
            HIDInteger(HIDProperty(device, CFSTR(kIOHIDPrimaryUsageKey)), 65535, &usage) && HIDUsageIsProtected((uint32_t)((page << 16) | usage))) continue;
        NSData *reportDescriptor = HIDProperty(device, CFSTR(kIOHIDReportDescriptorKey));
        NSDictionary *descriptor = HIDParseReportDescriptor(reportDescriptor, NULL);
        if (!descriptor) continue;
        record = [[HIDDeviceRecord alloc] init];
        record.device = (IOHIDDeviceRef)CFRetain(device); record.registryID = registryID;
        record.identifier = [@"hid:" stringByAppendingString:NSUUID.UUID.UUIDString];
        record.vendor = @(vendor); record.product = @(product); record.descriptor = descriptor;
        id name = HIDProperty(device, CFSTR(kIOHIDProductKey));
        record.productName = [name isKindOfClass:NSString.class] ? [name substringToIndex:MIN([name length], 512)] : @"HID device";
        id serial = HIDProperty(device, CFSTR(kIOHIDSerialNumberKey));
        id interface = CFBridgingRelease(IORegistryEntrySearchCFProperty(IOHIDDeviceGetService(device), kIOServicePlane,
            CFSTR("bInterfaceNumber"), kCFAllocatorDefault, kIORegistryIterateRecursively | kIORegistryIterateParents));
        NSArray *hardware = @[record.vendor, record.product];
        // Identical report descriptors may occur on multiple interfaces. Only
        // serial + interface + descriptor/usage is durable; incomplete identity
        // stays tied to this IOKit registry entry for the current boot.
        record.permissionDurable = PermissionSerialIsUsable(serial) && HIDInteger(interface, UINT8_MAX, NULL);
        record.permissionIdentity = record.permissionDurable ? PermissionIdentityKey(@[@"hid", @"serial", hardware,
            serial, interface, @(page), @(usage), PermissionDescriptorHash(reportDescriptor)]) :
            PermissionAttachmentIdentity(@"hid", hardware, registryID ? [NSString stringWithFormat:@"%llu", registryID] : @"", record.identifier);
        self.devices[record.identifier] = record; [seen addObject:record.identifier];
    }
    for (NSString *identifier in [self.devices.allKeys copy]) if (![seen containsObject:identifier]) [self removeDevice:identifier];
}
- (void)permissionDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *records))completion {
    dispatch_async(self.queue, ^{
        [self refreshDevices];
        NSMutableArray *records = [NSMutableArray array];
        for (HIDDeviceRecord *record in self.devices.allValues) {
            [records addObject:@{@"device": [self snapshot:record session:nil],
                @"identity": record.permissionIdentity, @"durable": @(record.permissionDurable)}];
        }
        completion(records);
    });
}

- (void)closeSession:(NSString *)session {
    if (![session isKindOfClass:NSString.class]) return;
    dispatch_async(self.queue, ^{
        for (HIDOpenDevice *opened in [self.opened.allValues copy]) if ([opened.session isEqual:session]) [self closeDevice:opened];
        [self.grants removeObjectForKey:session];
    });
}
- (NSDictionary *)openDevice:(HIDDeviceRecord *)record session:(NSString *)session {
    HIDOpenDevice *existing = self.opened[record.identifier];
    if (existing) return [existing.session isEqual:session] ? HIDSuccess([self snapshot:record session:session]) : HIDFailure(@"InvalidStateError", @"HID device is in use by another document.");
    IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, IOHIDDeviceGetService(record.device));
    if (!device) return HIDFailure(@"NotFoundError", @"HID device is unavailable.");
    // Recheck descriptors at open, before any access, including stale IDs.
    NSDictionary *descriptor = HIDParseReportDescriptor(HIDProperty(device, CFSTR(kIOHIDReportDescriptorKey)), NULL);
    NSUInteger vendor = 0, product = 0, page = 0, usage = 0;
    BOOL protectedPrimary = HIDInteger(HIDProperty(device, CFSTR(kIOHIDPrimaryUsagePageKey)), 65535, &page) &&
        HIDInteger(HIDProperty(device, CFSTR(kIOHIDPrimaryUsageKey)), 65535, &usage) && HIDUsageIsProtected((uint32_t)((page << 16) | usage));
    if (!descriptor || ![descriptor isEqual:record.descriptor] || protectedPrimary ||
        !HIDInteger(HIDProperty(device, CFSTR(kIOHIDVendorIDKey)), 65535, &vendor) || vendor != record.vendor.unsignedIntegerValue ||
        !HIDInteger(HIDProperty(device, CFSTR(kIOHIDProductIDKey)), 65535, &product) || product != record.product.unsignedIntegerValue) {
        CFRelease(device); return HIDFailure(@"SecurityError", @"HID identity or descriptor changed; choose the device again.");
    }
    IOReturn result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeSeizeDevice);
    if (result != kIOReturnSuccess) { CFRelease(device); return HIDIOFailure(result, @"Open HID device"); }
    HIDOpenDevice *opened = [[HIDOpenDevice alloc] init];
    opened.backend = self; opened.record = record; opened.session = session; opened.device = device;
    opened.pending = [NSMutableDictionary dictionary];
    NSUInteger maximum = 1;
    for (NSNumber *length in [record.descriptor[@"reportLengths"][@"input"] allValues]) maximum = MAX(maximum, length.unsignedIntegerValue + 1);
    opened.inputBuffer = [NSMutableData dataWithLength:maximum];
    IOHIDDeviceRegisterInputReportCallback(device, opened.inputBuffer.mutableBytes, (CFIndex)maximum, HIDInput, (__bridge void *)opened);
    IOHIDDeviceRegisterRemovalCallback(device, HIDRemoved, (__bridge void *)opened);
    IOHIDDeviceSetDispatchQueue(device, self.queue);
    IOHIDDeviceSetCancelHandler(device, ^{
        for (HIDPendingReport *pending in opened.pending.allValues) {
            if (pending.completion) { pending.completion(HIDFailure(@"AbortError", @"HID device closed during report operation.")); pending.completion = nil; }
        }
        [opened.pending removeAllObjects];
        opened.device = NULL;
        CFRelease(device);
    });
    self.opened[record.identifier] = opened;
    IOHIDDeviceActivate(device);
    return HIDSuccess([self snapshot:record session:session]);
}
- (void)inputReport:(HIDOpenDevice *)opened result:(IOReturn)result type:(IOHIDReportType)type
          reportID:(uint32_t)reportID bytes:(uint8_t *)bytes length:(CFIndex)length {
    if (opened.closing || result != kIOReturnSuccess || type != kIOHIDReportTypeInput || reportID > 255 || length < 0 ||
        ![self.grants[opened.session] containsObject:opened.record.identifier] || self.opened[opened.record.identifier] != opened) return;
    NSNumber *maximum = opened.record.descriptor[@"reportLengths"][@"input"][@(reportID)];
    if (!maximum || (NSUInteger)length > maximum.unsignedIntegerValue + (reportID ? 1 : 0) || (length && !bytes)) return;
    // macOS passes a numbered input report including its first report-ID byte.
    if (reportID) { if (!length || bytes[0] != reportID) return; bytes++; length--; }
    NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
    [self emit:@{@"event": @"hid.inputreport", @"deviceId": opened.record.identifier, @"reportId": @(reportID),
                 @"data": [data base64EncodedStringWithOptions:0]} session:opened.session];
}
- (void)finishReport:(HIDPendingReport *)pending result:(IOReturn)result bytes:(uint8_t *)bytes length:(CFIndex)length {
    HIDOpenDevice *opened = pending.owner;
    if (opened.pending[pending.identifier] != pending) return;
    NSDictionary *response = nil;
    if (opened.closing) response = HIDFailure(@"AbortError", @"HID device closed during report operation.");
    else if (result != kIOReturnSuccess) response = HIDIOFailure(result, @"HID report");
    else if (!pending.receiving) response = HIDSuccess(NSNull.null);
    else if (length < 0 || (NSUInteger)length > pending.buffer.length || (length && !bytes) ||
             (pending.reportID && (!length || bytes[0] != pending.reportID))) response = HIDFailure(@"DataError", @"HID returned a malformed feature report.");
    else response = HIDSuccess(@{@"data": [[NSData dataWithBytes:bytes length:(NSUInteger)length] base64EncodedStringWithOptions:0]});
    void (^completion)(NSDictionary *) = pending.completion; pending.completion = nil;
    [opened.pending removeObjectForKey:pending.identifier];
    if (completion) completion(response);
}
- (void)reportOperation:(NSString *)operation args:(NSDictionary *)args opened:(HIDOpenDevice *)opened
             completion:(void (^)(NSDictionary *response))completion {
    NSUInteger reportID = 0;
    if (!HIDInteger(args[@"reportId"], 255, &reportID)) { completion(HIDFailure(@"TypeError", @"Invalid HID report ID.")); return; }
    BOOL receiving = [operation isEqual:@"receiveFeatureReport"];
    NSString *kind = [operation isEqual:@"sendReport"] ? @"output" : @"feature";
    NSNumber *maximum = opened.record.descriptor[@"reportLengths"][kind][@(reportID)];
    if (!maximum) { completion(HIDFailure(@"NotAllowedError", @"Report ID/type is absent from the approved HID descriptor.")); return; }
    if (opened.pending.count >= HIDMaximumPendingReports) { completion(HIDFailure(@"QuotaExceededError", @"Too many pending HID reports.")); return; }
    NSMutableData *buffer = nil;
    if (receiving) {
        // IOHIDLibUserClient::getReport limits the complete buffer to 64 KiB.
        if (maximum.unsignedIntegerValue + (reportID ? 1 : 0) > 65536) {
            completion(HIDFailure(@"NotSupportedError", @"macOS feature-report reads are limited to 64 KiB including the report ID.")); return;
        }
        buffer = [NSMutableData dataWithLength:maximum.unsignedIntegerValue + (reportID ? 1 : 0)];
    }
    else {
        id encoded = args[@"data"];
        NSData *data = [encoded isKindOfClass:NSString.class] && [encoded length] <= ((HIDMaximumTransfer + 2) / 3) * 4 ? [[NSData alloc] initWithBase64EncodedString:encoded options:0] : nil;
        if (!data || data.length > maximum.unsignedIntegerValue || data.length > HIDMaximumTransfer) { completion(HIDFailure(@"DataError", @"Invalid or oversized HID report payload.")); return; }
        buffer = [NSMutableData dataWithCapacity:data.length + (reportID ? 1 : 0)];
        if (reportID) { uint8_t byte = (uint8_t)reportID; [buffer appendBytes:&byte length:1]; }
        [buffer appendData:data];
    }
    if (receiving && reportID) ((uint8_t *)buffer.mutableBytes)[0] = (uint8_t)reportID;
    HIDPendingReport *pending = [[HIDPendingReport alloc] init];
    pending.owner = opened; pending.identifier = NSUUID.UUID.UUIDString; pending.buffer = buffer;
    pending.receiving = receiving; pending.reportID = reportID; pending.completion = completion; pending->reportLength = (CFIndex)buffer.length;
    opened.pending[pending.identifier] = pending;
    // Apple's public wrappers and IOHIDLib implement asynchronous reports,
    // including IOKitUser-2022.41.3 (macOS 13). The timeout is milliseconds.
    // Older Chromium comments claiming these APIs are stubs are obsolete.
    IOReturn result;
    if (receiving) result = IOHIDDeviceGetReportWithCallback(opened.device, kIOHIDReportTypeFeature, (CFIndex)reportID,
                buffer.mutableBytes, &pending->reportLength, HIDReportTimeout * 1000, HIDReportComplete, (__bridge void *)pending);
    else result = IOHIDDeviceSetReportWithCallback(opened.device, [kind isEqual:@"output"] ? kIOHIDReportTypeOutput : kIOHIDReportTypeFeature,
                (CFIndex)reportID, buffer.bytes, (CFIndex)buffer.length, HIDReportTimeout * 1000, HIDReportComplete, (__bridge void *)pending);
    if (result != kIOReturnSuccess) { [self finishReport:pending result:result bytes:NULL length:0]; return; }
    // Defensive upper bound even if a driver never delivers its completion.
    // Buffers stay retained until device cancellation completes.
    __weak HIDBackend *weakSelf = self;
    __weak HIDPendingReport *weakPending = pending;
    __weak HIDOpenDevice *weakOpened = opened;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(HID_REPORT_GUARD_SECONDS * NSEC_PER_SEC)), self.queue, ^{
        HIDBackend *self = weakSelf;
        HIDPendingReport *pending = weakPending;
        HIDOpenDevice *opened = weakOpened;
        if (!self || !pending || !opened || opened.pending[pending.identifier] != pending || !pending.completion) return;
        pending.completion(HIDFailure(@"TimeoutError", @"HID report timed out; choose the device again.")); pending.completion = nil;
        // A driver that misses its own deadline has lost the logical connection.
        // Revoke the attachment and notify the page rather than leaving its
        // HIDDevice.opened flag true while the underlying handle is closed.
        [self removeDevice:opened.record.identifier];
    });
}
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session
            completion:(void (^)(NSDictionary *response))completion {
    if (!completion) return;
    dispatch_async(self.queue, ^{
        if (![operation isKindOfClass:NSString.class] || ![args isKindOfClass:NSDictionary.class] ||
            ![session isKindOfClass:NSString.class] || !session.length || session.length > 4096) {
            completion(HIDFailure(@"TypeError", @"Invalid HID request.")); return;
        }
        if (!self.manager) { completion(HIDFailure(@"NotSupportedError", @"macOS HID manager is unavailable.")); return; }
        [self refreshDevices];
        if ([operation isEqual:@"enumerate"] || [operation isEqual:@"getDevices"]) {
            NSMutableArray *result = [NSMutableArray array];
            for (HIDDeviceRecord *record in self.devices.allValues) if ([operation isEqual:@"enumerate"] || [self.grants[session] containsObject:record.identifier]) [result addObject:[self snapshot:record session:session]];
            completion(HIDSuccess(result)); return;
        }
        id identifier = args[@"deviceId"];
        if (![identifier isKindOfClass:NSString.class] || [identifier length] > 128) { completion(HIDFailure(@"TypeError", @"Invalid HID device ID.")); return; }
        if ([operation isEqual:@"grant"]) {
            HIDDeviceRecord *record = self.devices[identifier];
            if (!record) { completion(HIDFailure(@"NotFoundError", @"HID device is no longer available.")); return; }
            if (!self.grants[session]) self.grants[session] = [NSMutableSet set];
            [self.grants[session] addObject:identifier]; completion(HIDSuccess([self snapshot:record session:session])); return;
        }
        if (![self.grants[session] containsObject:identifier]) { completion(HIDFailure(@"SecurityError", @"HID device is not granted to this document.")); return; }
        HIDDeviceRecord *record = self.devices[identifier];
        if (!record) { completion(HIDFailure(@"NotFoundError", @"HID device disconnected.")); return; }
        HIDOpenDevice *opened = self.opened[identifier];
        if ([operation isEqual:@"open"]) { completion([self openDevice:record session:session]); return; }
        if ([operation isEqual:@"close"] || [operation isEqual:@"forget"]) {
            if ([opened.session isEqual:session]) [self closeDevice:opened];
            if ([operation isEqual:@"forget"]) [self.grants[session] removeObject:identifier];
            completion(HIDSuccess([self snapshot:record session:session])); return;
        }
        if (![opened.session isEqual:session] || opened.closing) { completion(HIDFailure(@"InvalidStateError", @"HID device is not open in this document.")); return; }
        if ([operation isEqual:@"sendReport"] || [operation isEqual:@"sendFeatureReport"] || [operation isEqual:@"receiveFeatureReport"]) {
            [self reportOperation:operation args:args opened:opened completion:completion]; return;
        }
        completion(HIDFailure(@"NotSupportedError", @"Unknown HID operation."));
    });
}
@end
