#import "../SerialBackend.h"
#import <util.h>
#import <fcntl.h>
#import <unistd.h>
#import <termios.h>
#import <errno.h>

@interface SerialBackend (Testing)
- (void)setTestPorts:(NSArray<NSDictionary *> *(^)(void))provider;
- (void)refreshForTesting;
@end
static NSUInteger assertions;
#define CHECK(expression) do { assertions++; if (!(expression)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); exit(1); } } while (0)
static BOOL fails(NSDictionary *result, NSString *name) { return [result[@"ok"] isEqual:@NO] && [result[@"error"][@"name"] isEqual:name]; }
static NSDictionary *call(SerialBackend *backend, NSString *session, NSString *operation, NSDictionary *args) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *result;
    [backend handleOperation:operation args:args ?: @{} session:session completion:^(NSDictionary *response) { result = response; dispatch_semaphore_signal(done); }];
    CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    return result;
}
static NSArray *permissions(SerialBackend *backend) {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSArray *records;
    [backend permissionDevicesWithCompletion:^(NSArray *result) { records = result; dispatch_semaphore_signal(ready); }];
    CHECK(dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
    return records;
}
static NSData *readBytes(int fd, NSUInteger length) {
    NSMutableData *result = [NSMutableData data];
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 1;
    while (result.length < length && NSProcessInfo.processInfo.systemUptime < deadline) {
        uint8_t buffer[256]; ssize_t count = read(fd, buffer, MIN(length - result.length, sizeof(buffer)));
        if (count > 0) [result appendBytes:buffer length:(NSUInteger)count];
        else { CHECK(count < 0 && (errno == EAGAIN || errno == EINTR)); usleep(1000); }
    }
    CHECK(result.length == length); return result;
}
int main(void) {
    @autoreleasepool {
        int master, slave; char path[1024];
        CHECK(openpty(&master, &slave, path, NULL, NULL) == 0);
        CHECK(fcntl(master, F_SETFL, O_NONBLOCK) == 0);
        close(slave);
        NSString *portPath = [NSString stringWithUTF8String:path];
        __block NSArray *inventory = @[@{@"path": portPath, @"registryId": @"fixture-1", @"productName": @"PTY fixture", @"usbVendorId": @0x451, @"usbProductId": @0xe018}];
        SerialBackend *backend = [SerialBackend new];
        [backend setTestPorts:^{ return inventory; }];
        NSMutableArray *events = [NSMutableArray array];
        dispatch_semaphore_t eventReady = dispatch_semaphore_create(0);
        backend.eventHandler = ^(NSString *session, NSDictionary *event) {
            @synchronized (events) { [events addObject:@{@"session": session, @"event": event}]; }
            dispatch_semaphore_signal(eventReady);
        };
        NSString *one = @"profile-a/document-1", *two = @"profile-a/document-2";
        CHECK(fails(call(backend, one, @"open", @{}), @"TypeError"));
        CHECK(fails(call(backend, @"", @"enumerate", nil), @"TypeError"));
        NSArray *ports = call(backend, one, @"enumerate", nil)[@"result"];
        CHECK(ports.count == 1);
        NSDictionary *snapshot = ports[0]; NSString *identifier = snapshot[@"id"];
        CHECK([snapshot[@"productName"] isEqual:@"PTY fixture"]);
        CHECK(snapshot[@"path"] == nil && snapshot[@"registryId"] == nil);
        CHECK([snapshot[@"usbVendorId"] isEqual:@0x451]);
        CHECK([snapshot[@"opened"] isEqual:@NO]);
        CHECK([snapshot[@"connected"] isEqual:@YES]);
        CHECK([call(backend, one, @"enumerate", nil)[@"result"][0][@"id"] isEqual:identifier]);
        CHECK([call(backend, one, @"getPorts", nil)[@"result"] count] == 0);
        NSDictionary *device = @{@"deviceId": identifier};
        CHECK(fails(call(backend, one, @"open", device), @"SecurityError"));
        CHECK(fails(call(backend, one, @"grant", @{@"deviceId": portPath}), @"NotFoundError"));
        CHECK([call(backend, one, @"grant", device)[@"ok"] boolValue]);
        CHECK([call(backend, one, @"getPorts", nil)[@"result"] count] == 1);
        CHECK([call(backend, two, @"getPorts", nil)[@"result"] count] == 0);
        CHECK(fails(call(backend, two, @"write", device), @"SecurityError"));
        NSMutableDictionary *options = [@{@"deviceId": identifier, @"baudRate": @115200, @"dataBits": @8, @"stopBits": @1,
                                          @"parity": @"none", @"flowControl": @"none", @"bufferSize": @255} mutableCopy];
        options[@"baudRate"] = @YES;
        CHECK(fails(call(backend, one, @"open", options), @"TypeError"));
        options[@"baudRate"] = @0;
        CHECK(fails(call(backend, one, @"open", options), @"TypeError"));
        options[@"baudRate"] = @115200; options[@"dataBits"] = @9;
        CHECK(fails(call(backend, one, @"open", options), @"TypeError"));
        options[@"dataBits"] = @8; options[@"parity"] = @"mark";
        CHECK(fails(call(backend, one, @"open", options), @"TypeError"));
        options[@"parity"] = @"none";
        CHECK([call(backend, one, @"open", options)[@"result"][@"opened"] boolValue]);
        CHECK(fails(call(backend, one, @"open", options), @"InvalidStateError"));
        CHECK([call(backend, two, @"grant", device)[@"ok"] boolValue]);
        CHECK(fails(call(backend, two, @"open", options), @"InvalidStateError"));
        CHECK(fails(call(backend, two, @"read", @{@"deviceId": identifier, @"length": @8}), @"InvalidStateError"));
        CHECK([call(backend, two, @"getPorts", nil)[@"result"][0][@"opened"] isEqual:@NO]);
        // Real POSIX I/O. Input waits in the kernel until one read grants credit;
        // any excess bytes remain there rather than filling an unbounded JS queue.
        CHECK(write(master, "abcdef", 6) == 6);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0);
        CHECK(fails(call(backend, one, @"read", @{@"deviceId": identifier, @"length": @65537}), @"TypeError"));
        CHECK(fails(call(backend, one, @"read", @{@"deviceId": identifier, @"length": @YES}), @"TypeError"));
        CHECK([call(backend, one, @"read", @{@"deviceId": identifier, @"length": @3})[@"result"] isEqual:NSNull.null]);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        NSDictionary *event;
        @synchronized (events) { event = events.lastObject; }
        CHECK([event[@"session"] isEqual:one]);
        CHECK([event[@"event"][@"event"] isEqual:@"serial.data"]);
        CHECK([event[@"event"][@"deviceId"] isEqual:identifier]);
        CHECK([[[NSData alloc] initWithBase64EncodedString:event[@"event"][@"data"] options:0] isEqual:[@"abc" dataUsingEncoding:NSUTF8StringEncoding]]);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0);
        CHECK([call(backend, one, @"read", @{@"deviceId": identifier, @"length": @64})[@"ok"] boolValue]);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        @synchronized (events) { event = events.lastObject; }
        CHECK([[[NSData alloc] initWithBase64EncodedString:event[@"event"][@"data"] options:0] isEqual:[@"def" dataUsingEncoding:NSUTF8StringEncoding]]);
        CHECK([call(backend, one, @"read", @{@"deviceId": identifier, @"length": @64})[@"ok"] boolValue]);
        CHECK(fails(call(backend, one, @"read", @{@"deviceId": identifier, @"length": @64}), @"InvalidStateError"));
        CHECK([call(backend, one, @"cancelRead", device)[@"ok"] boolValue]);
        CHECK(write(master, "cancelled", 9) == 9);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC)) != 0);
        CHECK([call(backend, one, @"read", @{@"deviceId": identifier, @"length": @64})[@"ok"] boolValue]);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        @synchronized (events) { event = events.lastObject; }
        CHECK([[[NSData alloc] initWithBase64EncodedString:event[@"event"][@"data"] options:0] isEqual:[@"cancelled" dataUsingEncoding:NSUTF8StringEncoding]]);
        const uint8_t rawOutput[] = {0, 1, 127, 128, 255, 10, 13};
        NSData *outgoing = [NSData dataWithBytes:rawOutput length:sizeof(rawOutput)];
        CHECK([call(backend, one, @"write", @{@"deviceId": identifier, @"data": [outgoing base64EncodedStringWithOptions:0]})[@"result"][@"bytesWritten"] unsignedIntegerValue] == outgoing.length);
        CHECK([[readBytes(master, outgoing.length) base64EncodedStringWithOptions:0] isEqual:[outgoing base64EncodedStringWithOptions:0]]);
        CHECK([call(backend, one, @"drain", device)[@"result"] isEqual:NSNull.null]);
        CHECK(fails(call(backend, one, @"write", @{@"deviceId": identifier, @"data": @"??bad"}), @"TypeError"));
        CHECK([call(backend, one, @"write", @{@"deviceId": identifier, @"data": @""})[@"result"][@"bytesWritten"] unsignedIntegerValue] == 0);
        CHECK(fails(call(backend, one, @"setSignals", @{@"deviceId": identifier, @"signals": @{@"dataTerminalReady": @1}}), @"TypeError"));
        CHECK(fails(call(backend, one, @"setSignals", @{@"deviceId": identifier, @"signals": @{@"unknown": @YES}}), @"TypeError"));
        CHECK([call(backend, one, @"setSignals", @{@"deviceId": identifier, @"signals": @{}})[@"ok"] boolValue]);
        // A pending credit never blocks output or another session's requests.
        CHECK([call(backend, one, @"read", @{@"deviceId": identifier, @"length": @64})[@"ok"] boolValue]);
        CHECK([call(backend, one, @"write", @{@"deviceId": identifier, @"data": @"WA=="})[@"ok"] boolValue]);
        CHECK([readBytes(master, 1) isEqual:[@"X" dataUsingEncoding:NSUTF8StringEncoding]]);
        CHECK([call(backend, two, @"getPorts", nil)[@"result"] count] == 1);
        CHECK([call(backend, one, @"close", device)[@"ok"] boolValue]);
        CHECK(fails(call(backend, one, @"read", @{@"deviceId": identifier, @"length": @64}), @"InvalidStateError"));
        CHECK([call(backend, two, @"open", options)[@"ok"] boolValue]);
        CHECK([call(backend, one, @"forget", device)[@"ok"] boolValue]);
        CHECK([call(backend, two, @"getPorts", nil)[@"result"][0][@"opened"] boolValue]);
        CHECK([call(backend, one, @"getPorts", nil)[@"result"] count] == 0);
        CHECK([call(backend, two, @"forget", device)[@"ok"] boolValue]);
        CHECK(fails(call(backend, two, @"write", device), @"SecurityError"));
        // Explicit closeSession releases both grants and the exclusive fd.
        CHECK([call(backend, one, @"grant", device)[@"ok"] boolValue]);
        CHECK([call(backend, one, @"open", options)[@"ok"] boolValue]);
        [backend closeSession:one];
        CHECK([call(backend, one, @"getPorts", nil)[@"result"] count] == 0);
        [backend refreshForTesting]; // Queue/cancellation barrier before reopening.
        CHECK([call(backend, two, @"grant", device)[@"ok"] boolValue]);
        CHECK([call(backend, two, @"open", options)[@"ok"] boolValue]);
        NSData *large = [NSMutableData dataWithLength:1024 * 1024];
        // Input still arrives while output is blocked; abort affects only output.
        dispatch_semaphore_t abortDone = dispatch_semaphore_create(0); __block NSDictionary *abortResult;
        [backend handleOperation:@"write" args:@{@"deviceId": identifier, @"data": [large base64EncodedStringWithOptions:0]} session:two completion:^(NSDictionary *response) {
            abortResult = response; dispatch_semaphore_signal(abortDone);
        }];
        CHECK([call(backend, two, @"read", @{@"deviceId": identifier, @"length": @64})[@"ok"] boolValue]);
        CHECK(write(master, "duplex", 6) == 6);
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        @synchronized (events) { event = events.lastObject; }
        CHECK([[[NSData alloc] initWithBase64EncodedString:event[@"event"][@"data"] options:0] isEqual:[@"duplex" dataUsingEncoding:NSUTF8StringEncoding]]);
        CHECK([call(backend, two, @"abortWrite", device)[@"result"] isEqual:NSNull.null]);
        CHECK(dispatch_semaphore_wait(abortDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        CHECK(fails(abortResult, @"AbortError"));
        CHECK([call(backend, two, @"getPorts", nil)[@"result"][0][@"opened"] boolValue]);
        uint8_t discard[4096]; while (read(master, discard, sizeof(discard)) > 0) {}
        CHECK([call(backend, two, @"write", @{@"deviceId": identifier, @"data": @"WA=="})[@"ok"] boolValue]);
        CHECK([readBytes(master, 1) isEqual:[@"X" dataUsingEncoding:NSUTF8StringEncoding]]);
        // A blocked write times out instead of wedging the native queue.
        dispatch_semaphore_t writeDone = dispatch_semaphore_create(0); __block NSDictionary *writeResult;
        [backend handleOperation:@"write" args:@{@"deviceId": identifier, @"data": [large base64EncodedStringWithOptions:0]} session:two completion:^(NSDictionary *response) {
            writeResult = response; dispatch_semaphore_signal(writeDone);
        }];
        CHECK([call(backend, one, @"getPorts", nil)[@"result"] count] == 0);
        CHECK(dispatch_semaphore_wait(writeDone, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        CHECK(fails(writeResult, @"TimeoutError"));
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        @synchronized (events) { event = events.lastObject; }
        CHECK([event[@"event"][@"event"] isEqual:@"serial.error"]);
        CHECK([event[@"event"][@"error"][@"name"] isEqual:@"TimeoutError"]);
        [backend refreshForTesting];
        CHECK([call(backend, two, @"getPorts", nil)[@"result"][0][@"opened"] isEqual:@NO]);
        CHECK([call(backend, two, @"open", options)[@"ok"] boolValue]);
        // Registry removal revokes grants and emits only to granted sessions.
        inventory = @[]; [backend refreshForTesting];
        CHECK(dispatch_semaphore_wait(eventReady, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        @synchronized (events) { event = events.lastObject; }
        CHECK([event[@"session"] isEqual:two]);
        CHECK([event[@"event"][@"event"] isEqual:@"serial.disconnect"]);
        CHECK([call(backend, two, @"getPorts", nil)[@"result"] count] == 0);
        CHECK(fails(call(backend, two, @"open", options), @"SecurityError"));
        inventory = @[@{@"path": portPath, @"registryId": @"fixture-2", @"productName": @"Replacement device"}];
        [backend refreshForTesting];
        CHECK(![call(backend, two, @"enumerate", nil)[@"result"][0][@"id"] isEqual:identifier]);
        CHECK([call(backend, two, @"getPorts", nil)[@"result"] count] == 0);
        [backend closeSession:one]; [backend closeSession:two]; [backend refreshForTesting];
        backend.eventHandler = nil;
        // Permission inventory is native-only and grants nothing by itself.
        NSDictionary *anonymous = permissions(backend).firstObject;
        CHECK([anonymous[@"durable"] isEqual:@NO]);
        CHECK(anonymous[@"device"][@"registryId"] == nil && anonymous[@"device"][@"path"] == nil);
        CHECK(anonymous[@"device"][@"identity"] == nil);
        SerialBackend *fresh = [SerialBackend new]; [fresh setTestPorts:^{ return inventory; }];
        CHECK([permissions(fresh).firstObject[@"identity"] isEqual:anonymous[@"identity"]]);
        NSMutableDictionary *port = [inventory.firstObject mutableCopy]; port[@"registryId"] = @"new-attachment";
        inventory = @[port];
        CHECK(![permissions(fresh).firstObject[@"identity"] isEqual:anonymous[@"identity"]]);
        port = [port mutableCopy]; port[@"usbVendorId"] = @0x451; port[@"usbProductId"] = @0xe018;
        port[@"usbSerialNumber"] = @"Adapter serial"; inventory = @[port];
        CHECK([permissions(fresh).firstObject[@"durable"] isEqual:@NO]); // missing interface
        port = [port mutableCopy]; port[@"usbInterfaceNumber"] = @0; inventory = @[port];
        NSDictionary *durable = permissions(fresh).firstObject;
        CHECK([durable[@"durable"] isEqual:@YES]);
        CHECK(durable[@"device"][@"usbSerialNumber"] == nil && durable[@"device"][@"usbInterfaceNumber"] == nil);
        port = [port mutableCopy]; port[@"registryId"] = @"replugged"; inventory = @[port];
        CHECK([permissions(fresh).firstObject[@"identity"] isEqual:durable[@"identity"]]);
        port = [port mutableCopy]; port[@"usbInterfaceNumber"] = @1; inventory = @[port];
        CHECK(![permissions(fresh).firstObject[@"identity"] isEqual:durable[@"identity"]]);
        NSMutableDictionary *duplicate = [port mutableCopy]; duplicate[@"registryId"] = @"ambiguous-second-port";
        inventory = @[port, duplicate];
        NSArray *ambiguous = permissions(fresh);
        CHECK(ambiguous.count == 2 && [ambiguous[0][@"identity"] isEqual:ambiguous[1][@"identity"]]);
        CHECK([call(fresh, @"new-document", @"getPorts", nil)[@"result"] count] == 0);
        inventory = @[@{@"registryId":@"0", @"path":portPath}];
        NSDictionary *unknownAttachment = permissions(fresh).firstObject;
        SerialBackend *unknownFresh = [SerialBackend new]; [unknownFresh setTestPorts:^{ return inventory; }];
        CHECK(![permissions(unknownFresh).firstObject[@"identity"] isEqual:unknownAttachment[@"identity"]]);
        close(master);
        printf("SerialBackend: %lu assertions passed (real PTY I/O; no serial hardware accessed).\n", (unsigned long)assertions);
    }
    return 0;
}
