#import "USBBackend.h"
#import <libusb.h>
#import <math.h>
#import <time.h>

static const NSUInteger USBMaximumTransfer = 1024 * 1024;
static const unsigned int USBTransferTimeout = 5000;
static const NSTimeInterval USBSessionLease = 60;
static const NSTimeInterval USBAdmissionTimeout = 10;

static NSTimeInterval USBNow(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static BOOL USBInteger(id value, NSUInteger maximum, NSUInteger *result) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0 || number > maximum || floor(number) != number) return NO;
    if (result) *result = (NSUInteger)number;
    return YES;
}

static BOOL USBString(id value, NSUInteger minimum, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] >= minimum && [value length] <= maximum;
}

static BOOL USBProtectedClass(uint8_t interfaceClass) {
    switch (interfaceClass) {
        case 0x01: case 0x03: case 0x08: case 0x09: case 0x0b:
        case 0x0e: case 0x10: case 0xe0: return YES;
        default: return NO;
    }
}

static BOOL USBOriginAllowed(NSString *origin) {
    if (!USBString(origin, 1, 2048)) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:origin];
    if (!url || url.user || url.password || url.query || url.fragment || (url.path.length && ![url.path isEqual:@""])) return NO;
    NSString *host = url.host.lowercaseString;
    if (!host.length) return NO;
    if ([url.scheme isEqual:@"https"]) return YES;
    return [url.scheme isEqual:@"http"] && ([host isEqual:@"localhost"] || [host isEqual:@"127.0.0.1"] || [host isEqual:@"[::1]"] || [host isEqual:@"::1"]);
}

@interface USBDeviceRecord : NSObject
@property(nonatomic) libusb_device *device;
@property(nonatomic) struct libusb_device_descriptor descriptor;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *manufacturer;
@property(nonatomic, copy) NSString *product;
@property(nonatomic, copy) NSString *serial;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSString *> *strings;
@end
@implementation USBDeviceRecord
- (void)dealloc { if (_device) libusb_unref_device(_device); }
@end

@interface USBOpenDevice : NSObject
@property(nonatomic) libusb_device_handle *handle;
@property(nonatomic) NSInteger configuration;
@property(nonatomic) NSMutableSet<NSNumber *> *claimed;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *alternates;
@end
@implementation USBOpenDevice
- (void)dealloc { if (_handle) libusb_close(_handle); }
@end

@interface USBSession : NSObject
@property(nonatomic, copy) NSString *origin;
@property(nonatomic) NSTimeInterval lastSeen;
@property(nonatomic) NSMutableSet<NSString *> *granted;
@property(nonatomic) NSMutableDictionary<NSString *, USBOpenDevice *> *opened;
@end
@implementation USBSession
@end

@interface USBBackend ()
@property(nonatomic) libusb_context *context;
@property(nonatomic) int initializationError;
@property(nonatomic, copy, readwrite) NSString *instance;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) dispatch_source_t expiryTimer;
@property(nonatomic) NSMutableDictionary<NSString *, USBDeviceRecord *> *devices;
@property(nonatomic) NSMutableDictionary<NSString *, USBSession *> *sessions;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *owners;
@end

@implementation USBBackend

+ (instancetype)sharedBackend {
    static USBBackend *backend;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ backend = [[self alloc] init]; });
    return backend;
}

- (instancetype)init {
    if ((self = [super init])) {
        _instance = NSUUID.UUID.UUIDString;
        _devices = [NSMutableDictionary dictionary];
        _sessions = [NSMutableDictionary dictionary];
        _owners = [NSMutableDictionary dictionary];
        _queue = dispatch_queue_create("org.webusb.safari.native.usb", DISPATCH_QUEUE_SERIAL);
        _initializationError = libusb_init(&_context);
        _expiryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_expiryTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
        __weak USBBackend *weakSelf = self;
        dispatch_source_set_event_handler(_expiryTimer, ^{
            @autoreleasepool {
                USBBackend *self = weakSelf;
                if (!self) return;
                [self expireSessions];
                [self refreshDevices];
            }
        });
        dispatch_resume(_expiryTimer);
    }
    return self;
}

- (void)dealloc {
    if (_expiryTimer) dispatch_source_cancel(_expiryTimer);
    for (NSString *key in [_sessions.allKeys copy]) [self closeSession:key];
    [_devices removeAllObjects];
    if (_context) libusb_exit(_context);
}

- (NSDictionary *)failure:(NSString *)name message:(NSString *)message {
    return @{@"ok": @NO, @"error": @{@"name": name, @"message": message}, @"instance": self.instance};
}
- (NSDictionary *)success:(id)result {
    return @{@"ok": @YES, @"result": result ?: NSNull.null, @"instance": self.instance};
}
- (NSDictionary *)usbFailure:(int)error action:(NSString *)action {
    NSString *name = @"NetworkError";
    if (error == LIBUSB_ERROR_NO_DEVICE) name = @"NotFoundError";
    else if (error == LIBUSB_ERROR_ACCESS) name = @"SecurityError";
    else if (error == LIBUSB_ERROR_NOT_SUPPORTED) name = @"NotSupportedError";
    else if (error == LIBUSB_ERROR_INVALID_PARAM) name = @"DataError";
    else if (error == LIBUSB_ERROR_TIMEOUT) name = @"TimeoutError";
    return [self failure:name message:[NSString stringWithFormat:@"%@: %s", action, libusb_error_name(error)]];
}

- (void)closeDevice:(NSString *)identifier session:(USBSession *)session {
    USBOpenDevice *opened = session.opened[identifier];
    if (opened) {
        for (NSNumber *number in opened.claimed) libusb_release_interface(opened.handle, number.intValue);
        [opened.claimed removeAllObjects];
        if (opened.handle) { libusb_close(opened.handle); opened.handle = NULL; }
        [session.opened removeObjectForKey:identifier];
        [self.owners removeObjectForKey:identifier];
    }
}
- (void)closeSession:(NSString *)key {
    USBSession *session = self.sessions[key];
    for (NSString *identifier in [session.opened.allKeys copy]) [self closeDevice:identifier session:session];
    [self.sessions removeObjectForKey:key];
}
- (void)expireSessions {
    NSTimeInterval now = USBNow();
    for (NSString *key in [self.sessions.allKeys copy]) {
        if (now - self.sessions[key].lastSeen >= USBSessionLease) [self closeSession:key];
    }
}

- (NSString *)readString:(uint8_t)index handle:(libusb_device_handle *)handle record:(USBDeviceRecord *)record {
    if (!index || !handle) return @"";
    NSString *cached = record.strings[@(index)];
    if (cached) return cached;
    unsigned char data[256];
    int length = libusb_get_string_descriptor_ascii(handle, index, data, sizeof(data));
    NSString *result = length > 0 ? [[NSString alloc] initWithBytes:data length:length encoding:NSUTF8StringEncoding] : @"";
    if (!result && length > 0) result = [[NSString alloc] initWithBytes:data length:length encoding:NSISOLatin1StringEncoding];
    record.strings[@(index)] = result ?: @"";
    return result ?: @"";
}

- (int)refreshDevices {
    if (self.initializationError < 0) return self.initializationError;
    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(self.context, &list);
    if (count < 0) return (int)count;
    NSMutableDictionary<NSValue *, USBDeviceRecord *> *known = [NSMutableDictionary dictionary];
    for (USBDeviceRecord *record in self.devices.allValues) known[[NSValue valueWithPointer:record.device]] = record;
    NSMutableSet *present = [NSMutableSet set];
    for (ssize_t i = 0; i < count; i++) {
        libusb_device *device = list[i];
        USBDeviceRecord *record = known[[NSValue valueWithPointer:device]];
        if (!record) {
            struct libusb_device_descriptor descriptor;
            if (libusb_get_device_descriptor(device, &descriptor) < 0 || USBProtectedClass(descriptor.bDeviceClass)) continue;
            record = [USBDeviceRecord new];
            record.device = libusb_ref_device(device);
            record.descriptor = descriptor;
            record.identifier = NSUUID.UUID.UUIDString;
            record.strings = [NSMutableDictionary dictionary];
            libusb_device_handle *temporary = NULL;
            libusb_open(device, &temporary); // Only descriptor reads; never claim/detach a kernel driver.
            record.manufacturer = [self readString:descriptor.iManufacturer handle:temporary record:record];
            record.product = [self readString:descriptor.iProduct handle:temporary record:record];
            record.serial = [self readString:descriptor.iSerialNumber handle:temporary record:record];
            if (temporary) {
                for (uint8_t c = 0; c < descriptor.bNumConfigurations; c++) {
                    struct libusb_config_descriptor *configuration = NULL;
                    if (libusb_get_config_descriptor(device, c, &configuration) < 0) continue;
                    [self readString:configuration->iConfiguration handle:temporary record:record];
                    for (uint8_t j = 0; j < configuration->bNumInterfaces; j++) {
                        for (int a = 0; a < configuration->interface[j].num_altsetting; a++) {
                            [self readString:configuration->interface[j].altsetting[a].iInterface handle:temporary record:record];
                        }
                    }
                    libusb_free_config_descriptor(configuration);
                }
                libusb_close(temporary);
            }
            self.devices[record.identifier] = record;
        }
        [present addObject:record.identifier];
    }
    libusb_free_device_list(list, 1);
    for (NSString *identifier in [self.devices.allKeys copy]) {
        if (![present containsObject:identifier]) {
            for (USBSession *session in self.sessions.allValues) {
                [self closeDevice:identifier session:session];
                [session.granted removeObject:identifier];
            }
            [self.devices removeObjectForKey:identifier];
        }
    }
    return 0;
}

- (struct libusb_config_descriptor *)configuration:(NSInteger)value record:(USBDeviceRecord *)record {
    if (value <= 0 || value > 255) return NULL;
    struct libusb_config_descriptor *configuration = NULL;
    if (libusb_get_config_descriptor_by_value(record.device, (uint8_t)value, &configuration) < 0) return NULL;
    return configuration;
}

- (NSDictionary *)snapshot:(USBDeviceRecord *)record session:(USBSession *)session {
    USBOpenDevice *opened = session.opened[record.identifier];
    struct libusb_device_descriptor d = record.descriptor;
    NSMutableArray *configurations = [NSMutableArray array];
    for (uint8_t c = 0; c < d.bNumConfigurations; c++) {
        struct libusb_config_descriptor *configuration = NULL;
        if (libusb_get_config_descriptor(record.device, c, &configuration) < 0) continue;
        NSMutableArray *interfaces = [NSMutableArray array];
        for (uint8_t i = 0; i < configuration->bNumInterfaces; i++) {
            const struct libusb_interface *interface = &configuration->interface[i];
            if (interface->num_altsetting < 1) continue;
            NSNumber *number = @(interface->altsetting[0].bInterfaceNumber);
            NSMutableArray *alternates = [NSMutableArray array];
            for (int a = 0; a < interface->num_altsetting; a++) {
                const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
                NSMutableArray *endpoints = [NSMutableArray array];
                for (uint8_t e = 0; e < alt->bNumEndpoints; e++) {
                    const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[e];
                    NSString *type;
                    switch (endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) {
                        case LIBUSB_TRANSFER_TYPE_BULK: type = @"bulk"; break;
                        case LIBUSB_TRANSFER_TYPE_INTERRUPT: type = @"interrupt"; break;
                        case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: type = @"isochronous"; break;
                        default: continue;
                    }
                    [endpoints addObject:@{@"endpointNumber": @(endpoint->bEndpointAddress & 0x0f),
                        @"direction": (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) ? @"in" : @"out",
                        @"type": type, @"packetSize": @(endpoint->wMaxPacketSize & 0x7ff)}];
                }
                [alternates addObject:@{@"alternateSetting": @(alt->bAlternateSetting), @"interfaceClass": @(alt->bInterfaceClass),
                    @"interfaceSubclass": @(alt->bInterfaceSubClass), @"interfaceProtocol": @(alt->bInterfaceProtocol),
                    @"interfaceName": record.strings[@(alt->iInterface)] ?: @"", @"endpoints": endpoints}];
            }
            BOOL active = opened && opened.configuration == configuration->bConfigurationValue;
            [interfaces addObject:@{@"interfaceNumber": number, @"claimed": @((active && [opened.claimed containsObject:number])),
                @"alternateSetting": active ? (opened.alternates[number] ?: @0) : @0, @"alternates": alternates}];
        }
        [configurations addObject:@{@"configurationValue": @(configuration->bConfigurationValue),
            @"configurationName": record.strings[@(configuration->iConfiguration)] ?: @"", @"interfaces": interfaces}];
        libusb_free_config_descriptor(configuration);
    }
    // BCD USB/device versions use a byte of major and one nibble each for minor/subminor.
    return @{@"id": record.identifier, @"usbVersionMajor": @(d.bcdUSB >> 8), @"usbVersionMinor": @((d.bcdUSB >> 4) & 15),
        @"usbVersionSubminor": @(d.bcdUSB & 15), @"deviceClass": @(d.bDeviceClass), @"deviceSubclass": @(d.bDeviceSubClass),
        @"deviceProtocol": @(d.bDeviceProtocol), @"vendorId": @(d.idVendor), @"productId": @(d.idProduct),
        @"deviceVersionMajor": @(d.bcdDevice >> 8), @"deviceVersionMinor": @((d.bcdDevice >> 4) & 15), @"deviceVersionSubminor": @(d.bcdDevice & 15),
        @"manufacturerName": record.manufacturer ?: @"", @"productName": record.product ?: @"", @"serialNumber": record.serial ?: @"",
        @"configurations": configurations, @"opened": @(opened != nil),
        @"configurationValue": (opened && opened.configuration > 0) ? @(opened.configuration) : NSNull.null};
}

- (BOOL)configurationProtected:(const struct libusb_config_descriptor *)configuration {
    if (!configuration) return NO;
    for (uint8_t i = 0; i < configuration->bNumInterfaces; i++) {
        const struct libusb_interface *interface = &configuration->interface[i];
        for (int a = 0; a < interface->num_altsetting; a++) if (USBProtectedClass(interface->altsetting[a].bInterfaceClass)) return YES;
    }
    return NO;
}
- (const struct libusb_interface *)interface:(NSUInteger)number configuration:(const struct libusb_config_descriptor *)configuration {
    if (!configuration) return NULL;
    for (uint8_t i = 0; i < configuration->bNumInterfaces; i++) {
        const struct libusb_interface *interface = &configuration->interface[i];
        if (interface->num_altsetting && interface->altsetting[0].bInterfaceNumber == number) return interface;
    }
    return NULL;
}
- (BOOL)interfaceProtected:(const struct libusb_interface *)interface {
    for (int a = 0; a < interface->num_altsetting; a++) if (USBProtectedClass(interface->altsetting[a].bInterfaceClass)) return YES;
    return NO;
}
- (const struct libusb_endpoint_descriptor *)endpoint:(uint8_t)address opened:(USBOpenDevice *)opened configuration:(const struct libusb_config_descriptor *)configuration {
    if (!configuration) return NULL;
    for (uint8_t i = 0; i < configuration->bNumInterfaces; i++) {
        const struct libusb_interface *interface = &configuration->interface[i];
        if (!interface->num_altsetting || [self interfaceProtected:interface]) continue;
        NSNumber *number = @(interface->altsetting[0].bInterfaceNumber);
        if (![opened.claimed containsObject:number]) continue;
        int selected = [opened.alternates[number] intValue];
        for (int a = 0; a < interface->num_altsetting; a++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
            if (alt->bAlternateSetting != selected) continue;
            for (uint8_t e = 0; e < alt->bNumEndpoints; e++) if (alt->endpoint[e].bEndpointAddress == address) return &alt->endpoint[e];
        }
    }
    return NULL;
}

- (NSDictionary *)admitMessage:(id)message profile:(NSString *)profile requestedAt:(NSTimeInterval)requestedAt {
    if (USBNow() - requestedAt >= USBAdmissionTimeout) {
        return [self failure:@"TimeoutError" message:@"Native USB queue is busy. The operation was not started."];
    }
    return [self processMessage:message profile:profile requestedAt:requestedAt];
}

- (NSDictionary *)handleMessage:(id)message profile:(NSString *)profile {
    NSTimeInterval requestedAt = USBNow();
    __block NSDictionary *response;
    dispatch_sync(self.queue, ^{
        @autoreleasepool { response = [self admitMessage:message profile:profile requestedAt:requestedAt]; }
    });
    return response;
}

- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *))completion {
    NSTimeInterval requestedAt = USBNow();
    dispatch_async(self.queue, ^{
        @autoreleasepool { completion([self admitMessage:message profile:profile requestedAt:requestedAt]); }
    });
}

- (NSDictionary *)processMessage:(id)message profile:(NSString *)profile requestedAt:(NSTimeInterval)requestedAt {
    [self expireSessions];
    if (![message isKindOfClass:NSDictionary.class] || !USBString(profile, 1, 256)) return [self failure:@"TypeError" message:@"Invalid native message or Safari profile."];
    NSUInteger version;
    if (!USBInteger(message[@"version"], 1, &version) || version != 1 || !USBString(message[@"op"], 1, 64)) return [self failure:@"TypeError" message:@"Unsupported protocol version or operation."];
    NSString *op = message[@"op"];
    NSDictionary *args = message[@"args"] ?: @{};
    if (![args isKindOfClass:NSDictionary.class]) return [self failure:@"TypeError" message:@"args must be an object."];
    if (![op isEqual:@"enumerate"] && ![self.instance isEqual:message[@"instance"]]) return [self failure:@"InvalidStateError" message:@"Native USB process restarted. Choose the device again."];
    if ([op isEqual:@"enumerate"]) {
        int result = [self refreshDevices];
        if (result < 0) return [self usbFailure:result action:@"Enumerate devices"];
        NSMutableArray *snapshots = [NSMutableArray array];
        for (USBDeviceRecord *record in self.devices.allValues) [snapshots addObject:[self snapshot:record session:nil]];
        return [self success:snapshots];
    }
    NSString *identifier = message[@"session"];
    NSString *origin = message[@"origin"];
    if (!USBString(identifier, 16, 128) || !USBOriginAllowed(origin)) return [self failure:@"SecurityError" message:@"A document session and secure top-level origin are required."];
    // JSON serialization makes the pair unambiguous, even if identifiers contain separators.
    NSData *keyData = [NSJSONSerialization dataWithJSONObject:@[profile, identifier] options:0 error:nil];
    NSString *key = [[NSString alloc] initWithData:keyData encoding:NSUTF8StringEncoding];
    USBSession *session = self.sessions[key];
    if (session && ![session.origin isEqual:origin]) return [self failure:@"SecurityError" message:@"Document session origin does not match its grant."];
    if ([op isEqual:@"closeSession"]) { if (session) [self closeSession:key]; return [self success:nil]; }
    if (session) session.lastSeen = USBNow();
    if ([op isEqual:@"heartbeat"]) return session ? [self success:nil] : [self failure:@"InvalidStateError" message:@"USB document session expired. Choose the device again."];
    int refreshResult = [self refreshDevices];
    if (refreshResult < 0) return [self usbFailure:refreshResult action:@"Refresh devices"];
    // Enumeration can spend time reading string descriptors. Recheck before any
    // grant, open, claim, transfer or other device mutation can start.
    if (USBNow() - requestedAt >= USBAdmissionTimeout) return [self failure:@"TimeoutError" message:@"USB discovery exceeded the operation admission deadline. Retry the request."];
    if ([op isEqual:@"getDevices"]) {
        NSMutableArray *snapshots = [NSMutableArray array];
        for (NSString *deviceId in session.granted) {
            USBDeviceRecord *record = self.devices[deviceId];
            if (record) [snapshots addObject:[self snapshot:record session:session]];
        }
        return [self success:snapshots];
    }
    NSString *deviceId = args[@"deviceId"];
    if (!USBString(deviceId, 1, 128)) return [self failure:@"TypeError" message:@"deviceId must be a nonempty opaque device identifier."];
    USBDeviceRecord *record = self.devices[deviceId];
    if (!record) return [self failure:@"NotFoundError" message:@"USB device disconnected or attachment identifier is stale."];
    if ([op isEqual:@"grant"]) {
        BOOL hasAllowedInterface = NO;
        for (uint8_t c = 0; c < record.descriptor.bNumConfigurations; c++) {
            struct libusb_config_descriptor *candidate = NULL;
            if (libusb_get_config_descriptor(record.device, c, &candidate) < 0) continue;
            for (uint8_t i = 0; i < candidate->bNumInterfaces; i++) {
                const struct libusb_interface *interface = &candidate->interface[i];
                if (interface->num_altsetting > 0 && ![self interfaceProtected:interface]) hasAllowedInterface = YES;
            }
            libusb_free_config_descriptor(candidate);
        }
        if (!hasAllowedInterface) return [self failure:@"SecurityError" message:@"Device has no interfaces permitted for WebUSB access."];
        if (!session) {
            session = [USBSession new];
            session.origin = origin;
            session.granted = [NSMutableSet set];
            session.opened = [NSMutableDictionary dictionary];
            self.sessions[key] = session;
        }
        session.lastSeen = USBNow();
        [session.granted addObject:deviceId];
        return [self success:[self snapshot:record session:session]];
    }
    if (!session || ![session.granted containsObject:deviceId]) return [self failure:@"SecurityError" message:@"Device is not granted to this document session."];
    USBOpenDevice *opened = session.opened[deviceId];
    if ([op isEqual:@"forget"]) {
        [self closeDevice:deviceId session:session];
        [session.granted removeObject:deviceId];
        return [self success:nil];
    }
    if ([op isEqual:@"close"]) {
        [self closeDevice:deviceId session:session];
        return [self success:[self snapshot:record session:session]];
    }
    if ([op isEqual:@"open"]) {
        if (opened) return [self success:[self snapshot:record session:session]];
        if (self.owners[deviceId]) return [self failure:@"NetworkError" message:@"Another document owns the device handle. Close it there first."];
        libusb_device_handle *handle = NULL;
        int result = libusb_open(record.device, &handle);
        if (result < 0) return [self usbFailure:result action:@"Open device"];
        int configuration = 0;
        result = libusb_get_configuration(handle, &configuration);
        if (result < 0) { libusb_close(handle); return [self usbFailure:result action:@"Read configuration"]; }
        opened = [USBOpenDevice new];
        opened.handle = handle;
        opened.configuration = configuration;
        opened.claimed = [NSMutableSet set];
        opened.alternates = [NSMutableDictionary dictionary];
        session.opened[deviceId] = opened;
        self.owners[deviceId] = key;
        return [self success:[self snapshot:record session:session]];
    }
    if (!opened) return [self failure:@"InvalidStateError" message:@"Open the device before using it."];
    if ([op isEqual:@"reset"]) {
        for (uint8_t c = 0; c < record.descriptor.bNumConfigurations; c++) {
            struct libusb_config_descriptor *candidate = NULL;
            if (libusb_get_config_descriptor(record.device, c, &candidate) < 0) return [self failure:@"NetworkError" message:@"Cannot validate configurations before reset."];
            BOOL protected = [self configurationProtected:candidate];
            libusb_free_config_descriptor(candidate);
            if (protected) return [self failure:@"SecurityError" message:@"Reset is blocked on devices containing protected interfaces."];
        }
        int result = libusb_reset_device(opened.handle);
        if (result < 0) {
            [self closeDevice:deviceId session:session];
            return [self usbFailure:result action:@"Reset device"];
        }
        // Release our interface claims after reset so later claims start from known state.
        for (NSNumber *number in opened.claimed) libusb_release_interface(opened.handle, number.intValue);
        [opened.claimed removeAllObjects];
        [opened.alternates removeAllObjects];
        int configuration = 0;
        result = libusb_get_configuration(opened.handle, &configuration);
        if (result < 0) { [self closeDevice:deviceId session:session]; return [self usbFailure:result action:@"Read reset configuration"]; }
        opened.configuration = configuration;
        return [self success:[self snapshot:record session:session]];
    }
    if ([op isEqual:@"selectConfiguration"]) {
        NSUInteger value;
        if (!USBInteger(args[@"configurationValue"], 255, &value) || value == 0) return [self failure:@"TypeError" message:@"configurationValue must be an integer from 1 to 255."];
        struct libusb_config_descriptor *configuration = [self configuration:value record:record];
        if (!configuration) return [self failure:@"NotFoundError" message:@"Configuration does not exist."];
        struct libusb_config_descriptor *current = [self configuration:opened.configuration record:record];
        BOOL protected = [self configurationProtected:configuration] || [self configurationProtected:current];
        libusb_free_config_descriptor(configuration);
        if (current) libusb_free_config_descriptor(current);
        if ((NSInteger)value == opened.configuration) return [self success:[self snapshot:record session:session]];
        if (protected) return [self failure:@"SecurityError" message:@"Changing configuration is blocked for devices containing protected interfaces."];
        if (opened.claimed.count) return [self failure:@"InvalidStateError" message:@"Release all interfaces before changing configuration."];
        int result = libusb_set_configuration(opened.handle, (int)value);
        if (result < 0) return [self usbFailure:result action:@"Select configuration"];
        opened.configuration = value;
        [opened.alternates removeAllObjects];
        return [self success:[self snapshot:record session:session]];
    }
    struct libusb_config_descriptor *configuration = [self configuration:opened.configuration record:record];
    if (!configuration) return [self failure:@"InvalidStateError" message:@"Select a configuration before using interfaces or transfers."];
    NSDictionary *response = [self interfaceOperation:op args:args record:record session:session opened:opened configuration:configuration];
    libusb_free_config_descriptor(configuration);
    return response;
}

- (NSDictionary *)interfaceOperation:(NSString *)op args:(NSDictionary *)args record:(USBDeviceRecord *)record session:(USBSession *)session opened:(USBOpenDevice *)opened configuration:(struct libusb_config_descriptor *)configuration {
    if ([op isEqual:@"claimInterface"] || [op isEqual:@"releaseInterface"] || [op isEqual:@"selectAlternateInterface"]) {
        NSUInteger number;
        if (!USBInteger(args[@"interfaceNumber"], 255, &number)) return [self failure:@"TypeError" message:@"interfaceNumber must be an integer from 0 to 255."];
        const struct libusb_interface *interface = [self interface:number configuration:configuration];
        if (!interface) return [self failure:@"NotFoundError" message:@"Interface does not exist in selected configuration."];
        if ([self interfaceProtected:interface]) return [self failure:@"SecurityError" message:@"Interface contains a protected USB class."];
        if ([op isEqual:@"claimInterface"]) {
            if (![opened.claimed containsObject:@(number)]) {
                int result = libusb_claim_interface(opened.handle, (int)number);
                if (result < 0) return [self usbFailure:result action:@"Claim interface (kernel drivers are never detached)"];
                // A single-alternate interface is already at alternate 0. Some devices
                // stall redundant SET_INTERFACE requests; only establish it when needed.
                if (interface->num_altsetting > 1) {
                    result = libusb_set_interface_alt_setting(opened.handle, (int)number, 0);
                    if (result < 0) {
                        libusb_release_interface(opened.handle, (int)number);
                        return [self usbFailure:result action:@"Select initial alternate setting"];
                    }
                }
                [opened.claimed addObject:@(number)];
                opened.alternates[@(number)] = @0;
            }
        } else if ([op isEqual:@"releaseInterface"]) {
            if ([opened.claimed containsObject:@(number)]) {
                int result = libusb_release_interface(opened.handle, (int)number);
                if (result < 0) return [self usbFailure:result action:@"Release interface"];
                [opened.claimed removeObject:@(number)];
                [opened.alternates removeObjectForKey:@(number)];
            }
        } else {
            NSUInteger alternate;
            if (!USBInteger(args[@"alternateSetting"], 255, &alternate)) return [self failure:@"TypeError" message:@"alternateSetting must be an integer from 0 to 255."];
            if (![opened.claimed containsObject:@(number)]) return [self failure:@"InvalidStateError" message:@"Claim the interface before selecting an alternate."];
            BOOL found = NO;
            for (int a = 0; a < interface->num_altsetting; a++) if (interface->altsetting[a].bAlternateSetting == alternate) found = YES;
            if (!found) return [self failure:@"NotFoundError" message:@"Alternate setting does not exist."];
            int result = libusb_set_interface_alt_setting(opened.handle, (int)number, (int)alternate);
            if (result < 0) return [self usbFailure:result action:@"Select alternate interface"];
            opened.alternates[@(number)] = @(alternate);
        }
        return [self success:[self snapshot:record session:session]];
    }
    if ([op isEqual:@"controlTransferIn"] || [op isEqual:@"controlTransferOut"]) return [self controlTransfer:op args:args opened:opened configuration:configuration];
    BOOL input = [op isEqual:@"transferIn"];
    if (!input && ![op isEqual:@"transferOut"] && ![op isEqual:@"clearHalt"]) return [self failure:@"NotSupportedError" message:@"Unsupported USB operation (isochronous transfers are not implemented)."];
    NSUInteger number;
    if (!USBInteger(args[@"endpointNumber"], 15, &number) || number == 0) return [self failure:@"TypeError" message:@"endpointNumber must be an integer from 1 to 15."];
    if ([op isEqual:@"clearHalt"]) {
        if (![@[@"in", @"out"] containsObject:args[@"direction"] ?: NSNull.null]) return [self failure:@"TypeError" message:@"direction must be in or out."];
        input = [args[@"direction"] isEqual:@"in"];
    }
    uint8_t address = (uint8_t)number | (input ? LIBUSB_ENDPOINT_IN : LIBUSB_ENDPOINT_OUT);
    const struct libusb_endpoint_descriptor *endpoint = [self endpoint:address opened:opened configuration:configuration];
    if (!endpoint) return [self failure:@"NotFoundError" message:@"Endpoint is not on a claimed, allowed, selected alternate interface."];
    int type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
    if (type != LIBUSB_TRANSFER_TYPE_BULK && type != LIBUSB_TRANSFER_TYPE_INTERRUPT) return [self failure:@"NotSupportedError" message:@"Only bulk and interrupt endpoints are supported."];
    if ([op isEqual:@"clearHalt"]) {
        int result = libusb_clear_halt(opened.handle, address);
        if (result < 0) return [self usbFailure:result action:@"Clear endpoint halt"];
        return [self success:[self snapshot:record session:session]];
    }
    NSUInteger length;
    NSMutableData *buffer;
    if (input) {
        if (!USBInteger(args[@"length"], USBMaximumTransfer, &length)) return [self failure:@"TypeError" message:@"Transfer length must be an integer from 0 to 1048576."];
        buffer = [NSMutableData dataWithLength:MAX(length, 1)];
    } else {
        NSString *encoded = args[@"data"];
        if (!USBString(encoded, 0, ((USBMaximumTransfer + 2) / 3) * 4)) return [self failure:@"TypeError" message:@"Transfer data must be bounded base64."];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!data || data.length > USBMaximumTransfer) return [self failure:@"TypeError" message:@"Transfer data is invalid base64 or exceeds 1 MiB."];
        length = data.length;
        buffer = [data mutableCopy];
        if (!length) [buffer setLength:1];
    }
    int transferred = 0;
    int result = type == LIBUSB_TRANSFER_TYPE_BULK
        ? libusb_bulk_transfer(opened.handle, address, buffer.mutableBytes, (int)length, &transferred, USBTransferTimeout)
        : libusb_interrupt_transfer(opened.handle, address, buffer.mutableBytes, (int)length, &transferred, USBTransferTimeout);
    if (result < 0 && result != LIBUSB_ERROR_PIPE) return [self usbFailure:result action:@"USB transfer"];
    if (transferred < 0 || (NSUInteger)transferred > length) return [self failure:@"NetworkError" message:@"USB driver returned an invalid transfer length."];
    NSString *status = result == LIBUSB_ERROR_PIPE ? @"stall" : @"ok";
    if (input) {
        [buffer setLength:(NSUInteger)transferred];
        return [self success:@{@"status": status, @"data": [buffer base64EncodedStringWithOptions:0]}];
    }
    return [self success:@{@"status": status, @"bytesWritten": @(transferred)}];
}

- (NSDictionary *)controlTransfer:(NSString *)op args:(NSDictionary *)args opened:(USBOpenDevice *)opened configuration:(struct libusb_config_descriptor *)configuration {
    NSDictionary *setup = args[@"setup"];
    if (![setup isKindOfClass:NSDictionary.class]) return [self failure:@"TypeError" message:@"Control setup must be an object."];
    NSDictionary *types = @{@"standard": @(LIBUSB_REQUEST_TYPE_STANDARD), @"class": @(LIBUSB_REQUEST_TYPE_CLASS), @"vendor": @(LIBUSB_REQUEST_TYPE_VENDOR)};
    NSDictionary *recipients = @{@"device": @(LIBUSB_RECIPIENT_DEVICE), @"interface": @(LIBUSB_RECIPIENT_INTERFACE), @"endpoint": @(LIBUSB_RECIPIENT_ENDPOINT), @"other": @(LIBUSB_RECIPIENT_OTHER)};
    id typeName = setup[@"requestType"], recipientName = setup[@"recipient"];
    if (!USBString(typeName, 1, 16) || !USBString(recipientName, 1, 16) || !types[typeName] || !recipients[recipientName]) return [self failure:@"TypeError" message:@"Invalid control requestType or recipient."];
    NSUInteger request = 0, value = 0, index = 0;
    if (!USBInteger(setup[@"request"], 255, &request) || !USBInteger(setup[@"value"], 65535, &value) || !USBInteger(setup[@"index"], 65535, &index)) return [self failure:@"TypeError" message:@"Control request, value and index must be unsigned integers of the correct width."];
    BOOL input = [op isEqual:@"controlTransferIn"];
    uint8_t type = [types[typeName] unsignedCharValue], recipient = [recipients[recipientName] unsignedCharValue];
    // These requests bypass the state API, or write device descriptors/address.
    if (type == LIBUSB_REQUEST_TYPE_STANDARD && (request == LIBUSB_REQUEST_SET_ADDRESS || request == LIBUSB_REQUEST_SET_DESCRIPTOR || request == LIBUSB_REQUEST_SET_CONFIGURATION || request == LIBUSB_REQUEST_SET_INTERFACE)) return [self failure:@"SecurityError" message:@"This standard control request is blocked; use the corresponding WebUSB state operation."];
    if (recipient == LIBUSB_RECIPIENT_INTERFACE) {
        const struct libusb_interface *interface = [self interface:index & 0xff configuration:configuration];
        if (!interface || [self interfaceProtected:interface] || ![opened.claimed containsObject:@(index & 0xff)]) return [self failure:@"SecurityError" message:@"Interface control transfers require a claimed, allowed interface."];
    } else if (recipient == LIBUSB_RECIPIENT_ENDPOINT) {
        uint8_t address = (uint8_t)(index & 0xff);
        if ((address & 0x70) || !(address & 0x0f) || ![self endpoint:address opened:opened configuration:configuration]) return [self failure:@"SecurityError" message:@"Endpoint control transfers require a claimed, allowed endpoint."];
    } else if ([self configurationProtected:configuration]) {
        return [self failure:@"SecurityError" message:@"Device-wide control transfers are blocked when the active configuration has protected interfaces."];
    }
    NSUInteger length;
    NSMutableData *buffer;
    if (input) {
        if (!USBInteger(args[@"length"], 65535, &length)) return [self failure:@"TypeError" message:@"Control transfer length must be an integer from 0 to 65535."];
        buffer = [NSMutableData dataWithLength:MAX(length, 1)];
    } else {
        NSString *encoded = args[@"data"];
        if (!USBString(encoded, 0, ((65535 + 2) / 3) * 4)) return [self failure:@"TypeError" message:@"Control transfer data must be bounded base64."];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!data || data.length > 65535) return [self failure:@"TypeError" message:@"Control data is invalid base64 or exceeds 65535 bytes."];
        length = data.length;
        buffer = [data mutableCopy];
        if (!length) [buffer setLength:1];
    }
    int result = libusb_control_transfer(opened.handle, (input ? LIBUSB_ENDPOINT_IN : LIBUSB_ENDPOINT_OUT) | type | recipient,
        (uint8_t)request, (uint16_t)value, (uint16_t)index, buffer.mutableBytes, (uint16_t)length, USBTransferTimeout);
    if (result < 0 && result != LIBUSB_ERROR_PIPE) return [self usbFailure:result action:@"USB control transfer"];
    NSUInteger transferred = result < 0 ? 0 : (NSUInteger)result;
    if (transferred > length) return [self failure:@"NetworkError" message:@"USB driver returned an invalid control transfer length."];
    NSString *status = result == LIBUSB_ERROR_PIPE ? @"stall" : @"ok";
    if (input) {
        [buffer setLength:transferred];
        return [self success:@{@"status": status, @"data": [buffer base64EncodedStringWithOptions:0]}];
    }
    return [self success:@{@"status": status, @"bytesWritten": @(transferred)}];
}
@end
