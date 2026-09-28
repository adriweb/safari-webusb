#import "SerialBackend.h"
#import "PermissionIdentity.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/serial/IOSerialKeys.h>
#import <IOKit/serial/ioss.h>
#import <sys/ioctl.h>
#import <sys/stat.h>
#import <termios.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>

#ifndef SERIAL_WRITE_TIMEOUT_SECONDS
#define SERIAL_WRITE_TIMEOUT_SECONDS 5.0
#endif
static const NSUInteger SerialMaxWrite = 1024 * 1024;
static const NSUInteger SerialMaxRead = 65536;

static NSDictionary *SerialOK(id result) { return @{@"ok": @YES, @"result": result ?: NSNull.null}; }
static NSDictionary *SerialError(NSString *name, NSString *message) {
    return @{@"ok": @NO, @"error": @{@"name": name, @"message": message}};
}
static NSDictionary *SerialSystemError(NSString *action) {
    int saved = errno;
    return SerialError(saved == EACCES || saved == EPERM ? @"SecurityError" : @"NetworkError",
                       [NSString stringWithFormat:@"%@: %s", action, strerror(saved)]);
}
static BOOL SerialInteger(id value, NSUInteger minimum, NSUInteger maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    return isfinite(number) && number == floor(number) && number >= minimum && number <= maximum;
}
static BOOL SerialBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}

@interface SerialConnection : NSObject
@property int fd;
@property NSString *deviceId;
@property NSString *session;
@property BOOL closing;
@property BOOL hardwareFlow;
@property struct termios originalSettings;
@property dispatch_source_t readSource;
@property dispatch_source_t writeSource;
@property BOOL reading;
@property BOOL writing;
@property NSUInteger readLength;
@property NSData *writeData;
@property NSUInteger writeOffset;
@property NSUInteger writeToken;
@property dispatch_source_t drainSource;
@property (copy) void (^drainCompletion)(NSDictionary *response);
@property (copy) void (^writeCompletion)(NSDictionary *response);
@property NSUInteger cancelCount;
@property NSMutableArray<void (^)(void)> *closeCompletions;
@end
@implementation SerialConnection
- (instancetype)init { if ((self = [super init])) { _fd = -1; _closeCompletions = [NSMutableArray array]; } return self; }
@end

@interface SerialBackend ()
@property dispatch_queue_t queue;
@property dispatch_source_t monitor;
@property NSMutableDictionary<NSString *, NSDictionary *> *devices;
@property NSMutableDictionary<NSString *, NSString *> *registryIds;
@property NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *grants;
@property NSMutableDictionary<NSString *, SerialConnection *> *connections;
#ifdef SERIAL_BACKEND_TESTING
@property (copy) NSArray<NSDictionary *> *(^testEnumeration)(void);
#endif
@end

@implementation SerialBackend
+ (instancetype)sharedBackend { static SerialBackend *backend; static dispatch_once_t once; dispatch_once(&once, ^{ backend = [self new]; }); return backend; }
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("org.webtilp.serial", DISPATCH_QUEUE_SERIAL);
        _devices = [NSMutableDictionary dictionary]; _registryIds = [NSMutableDictionary dictionary];
        _grants = [NSMutableDictionary dictionary]; _connections = [NSMutableDictionary dictionary];
        _monitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_monitor, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC * 100);
        __weak SerialBackend *weakSelf = self;
        dispatch_source_set_event_handler(_monitor, ^{ [weakSelf refreshDevices]; });
        dispatch_resume(_monitor);
    }
    return self;
}
- (void)dealloc { if (_monitor) dispatch_source_cancel(_monitor); }

// The injection seam is compiled only into the PTY tests; production paths are
// exclusively discovered from IOSerialBSDClient, never supplied by web content.
#ifdef SERIAL_BACKEND_TESTING
- (void)setTestPorts:(NSArray<NSDictionary *> *(^)(void))provider {
    dispatch_sync(self.queue, ^{ self.testEnumeration = provider; [self refreshDevices]; });
}
- (void)refreshForTesting { dispatch_sync(self.queue, ^{ [self refreshDevices]; }); }
#endif

static id SerialRegistryValue(io_registry_entry_t service, CFStringRef key) {
    return CFBridgingRelease(IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault,
                                                            kIORegistryIterateRecursively | kIORegistryIterateParents));
}
- (NSArray<NSDictionary *> *)enumeratePorts {
#ifdef SERIAL_BACKEND_TESTING
    if (self.testEnumeration) return self.testEnumeration();
#endif
    CFMutableDictionaryRef matching = IOServiceMatching(kIOSerialBSDServiceValue);
    if (!matching) return @[];
    CFDictionarySetValue(matching, CFSTR(kIOSerialBSDTypeKey), CFSTR(kIOSerialBSDAllTypes));
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) return @[];
    NSMutableArray *ports = [NSMutableArray array];
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        NSString *path = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR(kIOCalloutDeviceKey), kCFAllocatorDefault, 0));
        uint64_t registryId = 0;
        if ([path isKindOfClass:NSString.class] && [path hasPrefix:@"/dev/cu."] &&
            IORegistryEntryGetRegistryEntryID(service, &registryId) == KERN_SUCCESS) {
            id product = SerialRegistryValue(service, CFSTR("USB Product Name"));
            if (![product isKindOfClass:NSString.class] || ![product length])
                product = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR(kIOTTYDeviceKey), kCFAllocatorDefault, 0));
            NSMutableDictionary *port = [@{@"registryId": [NSString stringWithFormat:@"%llu", registryId], @"path": path,
                                          @"productName": [product isKindOfClass:NSString.class] ? product : @"Serial port"} mutableCopy];
            id vendor = SerialRegistryValue(service, CFSTR("idVendor"));
            id productId = SerialRegistryValue(service, CFSTR("idProduct"));
            if (SerialInteger(vendor, 0, UINT16_MAX)) port[@"usbVendorId"] = vendor;
            if (SerialInteger(productId, 0, UINT16_MAX)) port[@"usbProductId"] = productId;
            id serial = SerialRegistryValue(service, CFSTR("USB Serial Number"));
            id interface = SerialRegistryValue(service, CFSTR("bInterfaceNumber"));
            if (PermissionSerialIsUsable(serial)) port[@"usbSerialNumber"] = serial;
            if (SerialInteger(interface, 0, UINT8_MAX)) port[@"usbInterfaceNumber"] = interface;
            [ports addObject:port];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return ports;
}
- (void)emit:(NSDictionary *)event session:(NSString *)session {
    void (^handler)(NSString *, NSDictionary *) = self.eventHandler;
    if (handler) handler(session, event);
}
- (void)refreshDevices {
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    NSMutableDictionary *nextIds = [NSMutableDictionary dictionary];
    for (NSDictionary *port in [self enumeratePorts]) {
        NSString *key = port[@"registryId"];
        NSString *identifier = self.registryIds[key] ?: NSUUID.UUID.UUIDString;
        nextIds[key] = identifier;
        NSMutableDictionary *entry = [port mutableCopy]; entry[@"id"] = identifier;
        next[identifier] = entry;
    }
    for (NSString *identifier in self.devices.allKeys) {
        if (next[identifier]) continue;
        SerialConnection *connection = self.connections[identifier];
        if (connection) [self finishConnection:connection completion:nil];
        for (NSString *session in self.grants.allKeys) {
            if ([self.grants[session] containsObject:identifier]) {
                [self.grants[session] removeObject:identifier];
                [self emit:@{@"event": @"serial.disconnect", @"deviceId": identifier} session:session];
            }
        }
    }
    self.devices = next; self.registryIds = nextIds;
}
- (NSDictionary *)snapshot:(NSString *)identifier session:(NSString *)session {
    NSDictionary *device = self.devices[identifier];
    NSMutableDictionary *result = [@{@"id": identifier, @"productName": device[@"productName"] ?: @"Serial port",
                                     @"connected": @YES, @"opened": @([self.connections[identifier].session isEqual:session] && !self.connections[identifier].closing)} mutableCopy];
    for (NSString *key in @[@"usbVendorId", @"usbProductId"]) if (device[key]) result[key] = device[key];
    return result;
}
- (void)permissionDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *records))completion {
    dispatch_async(self.queue, ^{
        [self refreshDevices];
        NSMutableArray *records = [NSMutableArray array];
        for (NSString *identifier in self.devices) {
            NSDictionary *port = self.devices[identifier];
            NSArray *hardware = @[port[@"usbVendorId"] ?: NSNull.null, port[@"usbProductId"] ?: NSNull.null];
            // A USB serial number identifies the adapter, not necessarily its
            // port. Without the USB interface discriminator keep this grant
            // limited to the current attachment (also covers Bluetooth ports).
            BOOL durable = PermissionSerialIsUsable(port[@"usbSerialNumber"]) &&
                SerialInteger(port[@"usbVendorId"], 0, UINT16_MAX) && SerialInteger(port[@"usbProductId"], 0, UINT16_MAX) &&
                SerialInteger(port[@"usbInterfaceNumber"], 0, UINT8_MAX);
            NSString *attachment = port[@"registryId"];
            if (![attachment isKindOfClass:NSString.class] || [attachment isEqual:@"0"]) attachment = @"";
            NSString *identity = durable ? PermissionIdentityKey(@[@"serial", @"serial", hardware,
                port[@"usbSerialNumber"], port[@"usbInterfaceNumber"]]) :
                PermissionAttachmentIdentity(@"serial", hardware, attachment, identifier);
            [records addObject:@{@"device": [self snapshot:identifier session:nil], @"identity": identity, @"durable": @(durable)}];
        }
        completion(records);
    });
}

- (void)finishConnection:(SerialConnection *)connection completion:(void (^)(void))completion {
    if (completion) [connection.closeCompletions addObject:[completion copy]];
    if (connection.closing) return;
    connection.closing = YES;
    if (connection.writeCompletion) {
        void (^reply)(NSDictionary *) = connection.writeCompletion;
        connection.writeCompletion = nil; connection.writeData = nil; connection.writeToken++;
        reply(SerialError(@"AbortError", @"The serial port was closed during the write."));
    }
    if (connection.drainCompletion) {
        void (^reply)(NSDictionary *) = connection.drainCompletion;
        connection.drainCompletion = nil;
        dispatch_source_cancel(connection.drainSource); connection.drainSource = nil;
        reply(SerialError(@"AbortError", @"The serial port closed before its output drained."));
    }
    // Both readiness sources share fd. Close it only after both cancellation
    // handlers run so a recycled fd can never be observed by an old source.
    if (!connection.reading) dispatch_resume(connection.readSource);
    if (!connection.writing) dispatch_resume(connection.writeSource);
    dispatch_source_cancel(connection.readSource); dispatch_source_cancel(connection.writeSource);
}
- (void)sourceCancelled:(SerialConnection *)connection {
    if (++connection.cancelCount != 2) return;
    if (connection.fd >= 0) {
        // Restore line settings before releasing the exclusive open. Do not
        // drain: unresponsive hardware must not block browser/session cleanup.
        tcflush(connection.fd, TCOFLUSH);
        struct termios original = connection.originalSettings;
        tcsetattr(connection.fd, TCSANOW, &original);
        ioctl(connection.fd, TIOCNXCL); close(connection.fd); connection.fd = -1;
    }
    connection.readSource = nil; connection.writeSource = nil;
    if (self.connections[connection.deviceId] == connection) [self.connections removeObjectForKey:connection.deviceId];
    NSArray *completions = [connection.closeCompletions copy]; [connection.closeCompletions removeAllObjects];
    for (void (^completion)(void) in completions) completion();
}
- (void)failConnection:(SerialConnection *)connection error:(NSDictionary *)response {
    if (connection.closing) return;
    [self emit:@{@"event": @"serial.error", @"deviceId": connection.deviceId, @"error": response[@"error"]} session:connection.session];
    [self finishConnection:connection completion:nil];
}
- (void)readReady:(SerialConnection *)connection {
    if (connection.closing || !connection.reading) return;
    uint8_t buffer[65536];
    ssize_t count = read(connection.fd, buffer, connection.readLength);
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
    connection.reading = NO; dispatch_suspend(connection.readSource);
    if (count > 0) {
        NSData *data = [NSData dataWithBytes:buffer length:(NSUInteger)count];
        [self emit:@{@"event": @"serial.data", @"deviceId": connection.deviceId, @"data": [data base64EncodedStringWithOptions:0]}
               session:connection.session];
    } else {
        NSDictionary *error = count < 0 ? SerialSystemError(@"Reading the serial port failed") : SerialError(@"NetworkError", @"The serial port disconnected.");
        [self failConnection:connection error:error];
    }
}
- (void)writeReady:(SerialConnection *)connection {
    if (connection.closing || !connection.writing) return;
    NSUInteger remaining = connection.writeData.length - connection.writeOffset;
    ssize_t count = write(connection.fd, (const uint8_t *)connection.writeData.bytes + connection.writeOffset, MIN(remaining, (NSUInteger)16384));
    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return;
    NSDictionary *error = nil;
    if (count < 0) error = SerialSystemError(@"Writing the serial port failed");
    else connection.writeOffset += (NSUInteger)count;
    if (!error && connection.writeOffset < connection.writeData.length) return;
    connection.writing = NO; dispatch_suspend(connection.writeSource);
    void (^reply)(NSDictionary *) = connection.writeCompletion;
    NSUInteger written = connection.writeOffset;
    connection.writeCompletion = nil; connection.writeData = nil; connection.writeToken++;
    if (reply) reply(error ?: SerialOK(@{@"bytesWritten": @(written)}));
    if (error) [self failConnection:connection error:error];
}
- (void)drain:(SerialConnection *)connection completion:(void (^)(NSDictionary *))completion {
    if (connection.writing || connection.drainCompletion) {
        completion(SerialError(@"InvalidStateError", @"Serial output is already writing or draining.")); return;
    }
    // Writable readiness means buffer space, not that the output has drained.
    // TIOCOUTQ checks let other ports and pending input continue while hardware
    // transmits; tcdrain() would block the serial queue indefinitely on CTS.
    connection.drainCompletion = completion;
    connection.drainSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(connection.drainSource, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + SERIAL_WRITE_TIMEOUT_SECONDS;
    __weak SerialBackend *weakSelf = self;
    dispatch_source_set_event_handler(connection.drainSource, ^{
        if (connection.closing || !connection.drainCompletion) return;
        int remaining = 0;
        NSDictionary *error = nil;
        if (ioctl(connection.fd, TIOCOUTQ, &remaining) < 0) error = SerialSystemError(@"Draining serial output failed");
        else if (remaining > 0 && NSProcessInfo.processInfo.systemUptime < deadline) return;
        else if (remaining > 0) error = SerialError(@"TimeoutError", @"Serial output did not drain; the port was closed.");
        void (^reply)(NSDictionary *) = connection.drainCompletion; connection.drainCompletion = nil;
        dispatch_source_cancel(connection.drainSource); connection.drainSource = nil;
        if (error) [weakSelf failConnection:connection error:error];
        reply(error ?: SerialOK(nil));
    });
    dispatch_resume(connection.drainSource);
}
- (NSDictionary *)openDevice:(NSString *)identifier args:(NSDictionary *)args session:(NSString *)session {
    if (self.connections[identifier]) return SerialError(@"InvalidStateError", @"The serial port is already open or closing.");
    id baud = args[@"baudRate"], dataBits = args[@"dataBits"] ?: @8, stopBits = args[@"stopBits"] ?: @1;
    id parity = args[@"parity"] ?: @"none", flow = args[@"flowControl"] ?: @"none", bufferSize = args[@"bufferSize"] ?: @255;
    if (!SerialInteger(baud, 1, UINT32_MAX) || !SerialInteger(dataBits, 7, 8) || !SerialInteger(stopBits, 1, 2) ||
        ![@[@"none", @"even", @"odd"] containsObject:parity] || ![@[@"none", @"hardware"] containsObject:flow] ||
        !SerialInteger(bufferSize, 1, SerialMaxWrite)) return SerialError(@"TypeError", @"Invalid serial port options.");
    NSString *path = self.devices[identifier][@"path"];
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return SerialSystemError(@"Opening the serial port failed");
    struct stat status;
    struct termios original, settings;
    if (fstat(fd, &status) < 0 || !S_ISCHR(status.st_mode) || ioctl(fd, TIOCEXCL) < 0 || tcgetattr(fd, &original) < 0) {
        NSDictionary *error = SerialSystemError(@"Preparing the serial port failed"); close(fd); return error;
    }
    settings = original; cfmakeraw(&settings);
    settings.c_cflag &= ~(CSIZE | CSTOPB | PARENB | PARODD | CRTSCTS | CDTR_IFLOW | CDSR_OFLOW | CCAR_OFLOW);
    settings.c_cflag |= CLOCAL | CREAD | ([dataBits unsignedIntegerValue] == 7 ? CS7 : CS8);
    if ([stopBits unsignedIntegerValue] == 2) settings.c_cflag |= CSTOPB;
    if (![parity isEqual:@"none"]) { settings.c_cflag |= PARENB; if ([parity isEqual:@"odd"]) settings.c_cflag |= PARODD; }
    if ([flow isEqual:@"hardware"]) settings.c_cflag |= CRTSCTS;
    settings.c_cc[VMIN] = 1; settings.c_cc[VTIME] = 0;
    speed_t speed = [baud unsignedIntValue];
    BOOL standard = [@[@50,@75,@110,@134,@150,@200,@300,@600,@1200,@1800,@2400,@4800,@9600,@19200,@38400,@57600,@115200,@230400] containsObject:baud];
    cfsetspeed(&settings, standard ? speed : B9600);
    if (tcsetattr(fd, TCSANOW, &settings) < 0 || (!standard && ioctl(fd, IOSSIOSPEED, &speed) < 0)) {
        NSDictionary *error = SerialSystemError(@"Configuring the serial port failed");
        tcsetattr(fd, TCSANOW, &original); ioctl(fd, TIOCNXCL); close(fd); return error;
    }
    // Stale input left by a prior owner must not enter a newly opened stream.
    tcflush(fd, TCIOFLUSH);
    SerialConnection *connection = [SerialConnection new]; connection.fd = fd;
    connection.deviceId = identifier; connection.session = session; connection.originalSettings = original;
    connection.hardwareFlow = [flow isEqual:@"hardware"];
    connection.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.queue);
    connection.writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, self.queue);
    __weak SerialBackend *weakSelf = self;
    dispatch_source_set_event_handler(connection.readSource, ^{ [weakSelf readReady:connection]; });
    dispatch_source_set_event_handler(connection.writeSource, ^{ [weakSelf writeReady:connection]; });
    dispatch_source_set_cancel_handler(connection.readSource, ^{ [weakSelf sourceCancelled:connection]; });
    dispatch_source_set_cancel_handler(connection.writeSource, ^{ [weakSelf sourceCancelled:connection]; });
    self.connections[identifier] = connection;
    return SerialOK([self snapshot:identifier session:session]);
}
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session completion:(void (^)(NSDictionary *))completion {
    dispatch_async(self.queue, ^{ [self performOperation:operation args:args session:session completion:completion]; });
}
- (void)performOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session completion:(void (^)(NSDictionary *))completion {
    if (![operation isKindOfClass:NSString.class] || ![args isKindOfClass:NSDictionary.class] || ![session isKindOfClass:NSString.class] || !session.length) {
        completion(SerialError(@"TypeError", @"Invalid serial request.")); return;
    }
    if ([operation isEqual:@"enumerate"] || [operation isEqual:@"getPorts"] || [operation isEqual:@"grant"]) [self refreshDevices];
    if ([operation isEqual:@"enumerate"] || [operation isEqual:@"getPorts"]) {
        NSMutableArray *ports = [NSMutableArray array];
        for (NSString *identifier in [self.devices.allKeys sortedArrayUsingSelector:@selector(compare:)])
            if ([operation isEqual:@"enumerate"] || [self.grants[session] containsObject:identifier]) [ports addObject:[self snapshot:identifier session:session]];
        completion(SerialOK(ports)); return;
    }
    NSString *identifier = args[@"deviceId"];
    if (![identifier isKindOfClass:NSString.class]) { completion(SerialError(@"TypeError", @"Missing serial port identifier.")); return; }
    if ([operation isEqual:@"grant"]) {
        if (!self.devices[identifier]) { completion(SerialError(@"NotFoundError", @"The serial port is no longer connected.")); return; }
        if (!self.grants[session]) self.grants[session] = [NSMutableSet set];
        if (self.grants[session].count >= 64 && ![self.grants[session] containsObject:identifier]) { completion(SerialError(@"QuotaExceededError", @"Too many serial port grants.")); return; }
        [self.grants[session] addObject:identifier]; completion(SerialOK([self snapshot:identifier session:session])); return;
    }
    if (![self.grants[session] containsObject:identifier]) { completion(SerialError(@"SecurityError", @"This document has not been granted access to the serial port.")); return; }
    SerialConnection *connection = self.connections[identifier];
    if ([operation isEqual:@"forget"]) {
        [self.grants[session] removeObject:identifier];
        if ([connection.session isEqual:session]) [self finishConnection:connection completion:^{ completion(SerialOK(nil)); }];
        else completion(SerialOK(nil)); return;
    }
    if (!self.devices[identifier]) { completion(SerialError(@"NotFoundError", @"The serial port is no longer connected.")); return; }
    if ([operation isEqual:@"open"]) { completion([self openDevice:identifier args:args session:session]); return; }
    if (!connection || ![connection.session isEqual:session] || connection.closing) { completion(SerialError(@"InvalidStateError", @"The serial port is not open in this document.")); return; }
    if ([operation isEqual:@"close"]) {
        if (connection.writing) [self finishConnection:connection completion:^{ completion(SerialOK(nil)); }];
        else [self drain:connection completion:^(NSDictionary *response) {
            [self finishConnection:connection completion:^{ completion(response); }];
        }];
        return;
    }
    if ([operation isEqual:@"drain"]) { [self drain:connection completion:completion]; return; }
    if ([operation isEqual:@"abortWrite"]) {
        if (connection.writing) {
            connection.writing = NO; dispatch_suspend(connection.writeSource);
            void (^reply)(NSDictionary *) = connection.writeCompletion;
            connection.writeCompletion = nil; connection.writeData = nil; connection.writeToken++;
            if (reply) reply(SerialError(@"AbortError", @"The serial write was aborted."));
        }
        if (connection.drainCompletion) {
            void (^reply)(NSDictionary *) = connection.drainCompletion; connection.drainCompletion = nil;
            dispatch_source_cancel(connection.drainSource); connection.drainSource = nil;
            reply(SerialError(@"AbortError", @"Draining serial output was aborted."));
        }
        if (tcflush(connection.fd, TCOFLUSH) < 0) completion(SerialSystemError(@"Flushing serial output failed"));
        else completion(SerialOK(nil));
        return;
    }
    if ([operation isEqual:@"read"]) {
        if (!SerialInteger(args[@"length"], 1, SerialMaxRead)) { completion(SerialError(@"TypeError", @"Invalid serial read size.")); return; }
        if (connection.reading) { completion(SerialError(@"InvalidStateError", @"A serial read is already pending.")); return; }
        connection.readLength = [args[@"length"] unsignedIntegerValue]; connection.reading = YES;
        // Reply precedes any event so consumers can arm their credit state.
        completion(SerialOK(nil)); dispatch_resume(connection.readSource); return;
    }
    if ([operation isEqual:@"cancelRead"]) {
        if (connection.reading) { connection.reading = NO; dispatch_suspend(connection.readSource); }
        completion(SerialOK(nil)); return;
    }
    if ([operation isEqual:@"write"]) {
        NSString *encoded = args[@"data"];
        if (![encoded isKindOfClass:NSString.class] || encoded.length > 4 * ((SerialMaxWrite + 2) / 3)) { completion(SerialError(@"TypeError", @"Invalid serial write data.")); return; }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        if (!data || data.length > SerialMaxWrite) { completion(SerialError(@"TypeError", @"Invalid serial write data.")); return; }
        if (connection.writing || connection.drainCompletion) { completion(SerialError(@"InvalidStateError", @"Serial output is already writing or draining.")); return; }
        if (!data.length) { completion(SerialOK(@{@"bytesWritten": @0})); return; }
        connection.writeData = data; connection.writeOffset = 0; connection.writeCompletion = completion; connection.writing = YES;
        NSUInteger token = ++connection.writeToken;
        dispatch_resume(connection.writeSource);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SERIAL_WRITE_TIMEOUT_SECONDS * NSEC_PER_SEC)), self.queue, ^{
            if (connection.closing || !connection.writing || token != connection.writeToken) return;
            connection.writing = NO; dispatch_suspend(connection.writeSource);
            void (^reply)(NSDictionary *) = connection.writeCompletion; connection.writeCompletion = nil; connection.writeData = nil; connection.writeToken++;
            NSDictionary *error = SerialError(@"TimeoutError", @"The serial write timed out; the port was closed to avoid continuing a partial write.");
            if (reply) reply(error);
            [self failConnection:connection error:error];
        }); return;
    }
    if ([operation isEqual:@"getSignals"]) {
        int signals;
        if (ioctl(connection.fd, TIOCMGET, &signals) < 0) { completion(SerialSystemError(@"Reading serial signals failed")); return; }
        completion(SerialOK(@{@"clearToSend": @((signals & TIOCM_CTS) != 0), @"dataCarrierDetect": @((signals & TIOCM_CAR) != 0),
                              @"dataSetReady": @((signals & TIOCM_DSR) != 0), @"ringIndicator": @((signals & TIOCM_RI) != 0)})); return;
    }
    if ([operation isEqual:@"setSignals"]) {
        NSDictionary *signals = args[@"signals"];
        if (![signals isKindOfClass:NSDictionary.class]) { completion(SerialError(@"TypeError", @"Invalid serial signals.")); return; }
        for (NSString *key in signals) {
            if (![@[@"dataTerminalReady", @"requestToSend", @"break"] containsObject:key] || !SerialBoolean(signals[key])) { completion(SerialError(@"TypeError", @"Invalid serial signal value.")); return; }
        }
        if (signals[@"requestToSend"] && connection.hardwareFlow) { completion(SerialError(@"InvalidStateError", @"RTS is controlled by hardware flow control.")); return; }
        // Set only requested bits. TIOCMSET would overwrite unrelated signals.
        int set = 0, clear = 0;
        for (NSString *key in @[@"dataTerminalReady", @"requestToSend"]) if (signals[key]) {
            int bit = [key isEqual:@"dataTerminalReady"] ? TIOCM_DTR : TIOCM_RTS;
            if ([signals[key] boolValue]) set |= bit; else clear |= bit;
        }
        if ((set && ioctl(connection.fd, TIOCMBIS, &set) < 0) || (clear && ioctl(connection.fd, TIOCMBIC, &clear) < 0) ||
            (signals[@"break"] && ioctl(connection.fd, [signals[@"break"] boolValue] ? TIOCSBRK : TIOCCBRK) < 0)) {
            completion(SerialSystemError(@"Setting serial signals failed")); return;
        }
        completion(SerialOK(nil)); return;
    }
    completion(SerialError(@"NotSupportedError", @"Unsupported serial operation."));
}
- (void)closeSession:(NSString *)session {
    dispatch_async(self.queue, ^{
        [self.grants removeObjectForKey:session];
        for (SerialConnection *connection in self.connections.allValues)
            if ([connection.session isEqual:session]) [self finishConnection:connection completion:nil];
    });
}
@end
