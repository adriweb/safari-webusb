#import "../USBBackend.h"
#import "FakeUSB.h"
#import <libusb.h>

// Private entry points let us test expired admission without sleeping or
// introducing a production clock-override API.
@interface USBBackend (AdmissionTesting)
- (NSDictionary *)admitMessage:(id)message profile:(NSString *)profile requestedAt:(NSTimeInterval)requestedAt;
- (NSDictionary *)processMessage:(id)message profile:(NSString *)profile requestedAt:(NSTimeInterval)requestedAt;
@end

static NSUInteger assertions;
#define CHECK(expression) do { assertions++; if (!(expression)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expression); exit(1); } } while (0)
static NSDictionary *call(USBBackend *backend, NSString *instance, NSString *session, NSString *profile, NSString *op, NSDictionary *args) {
    return [backend handleMessage:@{@"version": @1, @"instance": instance, @"session": session, @"origin": @"https://example.com", @"op": op, @"args": args ?: @{}} profile:profile];
}
static BOOL fails(NSDictionary *response, NSString *name) { return [response[@"ok"] isEqual:@NO] && [response[@"error"][@"name"] isEqual:name]; }
int main(void) {
    @autoreleasepool {
        USBBackend *backend = [USBBackend new];
        NSString *session = @"session-one-123456789";
        NSString *session2 = @"session-two-123456789";
        NSString *profile = @"profile-one";
        CHECK(fails([backend handleMessage:NSNull.null profile:profile], @"TypeError"));
        CHECK(fails([backend handleMessage:@{@"version": @YES, @"op": @"enumerate"} profile:profile], @"TypeError"));
        NSDictionary *enumeration = [backend handleMessage:@{@"version": @1, @"op": @"enumerate"} profile:profile];
        CHECK([enumeration[@"ok"] boolValue]);
        CHECK([enumeration[@"result"] count] == 1);
        NSString *instance = enumeration[@"instance"];
        NSString *deviceId = enumeration[@"result"][0][@"id"];
        CHECK(fake_usb_open_handles() == 0);
        CHECK(fake_usb_ref_balance() == 1);
        NSDictionary *device = @{@"deviceId": deviceId};
        CHECK(fails([backend admitMessage:@{@"version": @1, @"op": @"enumerate"} profile:profile requestedAt:-60], @"TimeoutError"));
        @autoreleasepool {
            CHECK(fails([backend processMessage:@{@"version": @1, @"op": @"grant", @"instance": instance, @"session": session, @"origin": @"https://example.com", @"args": device} profile:profile requestedAt:-60], @"TimeoutError"));
        }
        CHECK([call(backend, instance, session, profile, @"getDevices", nil)[@"result"] count] == 0);
        dispatch_semaphore_t completion = dispatch_semaphore_create(0);
        __block BOOL asyncWorked = NO;
        [backend handleMessage:@{@"version": @1, @"op": @"enumerate"} profile:profile completion:^(NSDictionary *response) {
            asyncWorked = [response[@"ok"] boolValue];
            dispatch_semaphore_signal(completion);
        }];
        CHECK(dispatch_semaphore_wait(completion, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0);
        CHECK(asyncWorked);
        CHECK(fails(call(backend, @"stale", session, profile, @"getDevices", nil), @"InvalidStateError"));
        CHECK([call(backend, instance, session, profile, @"getDevices", nil)[@"result"] count] == 0);
        CHECK(fails(call(backend, instance, session, profile, @"open", device), @"SecurityError"));
        CHECK([call(backend, instance, session, profile, @"grant", device)[@"ok"] boolValue]);
        CHECK([call(backend, instance, session, profile, @"open", device)[@"result"][@"opened"] boolValue]);
        CHECK(fake_usb_open_handles() == 1);
        CHECK(fails([backend handleMessage:@{@"version": @1, @"instance": instance, @"session": session, @"origin": @"https://attacker.example", @"op": @"getDevices"} profile:profile], @"SecurityError"));
        CHECK(fails([backend handleMessage:@{@"version": @1, @"instance": instance, @"session": session2, @"origin": @"http://example.com", @"op": @"grant", @"args": device} profile:profile], @"SecurityError"));
        CHECK(fails(call(backend, instance, session, @"profile-two", @"open", device), @"SecurityError"));
        CHECK([call(backend, instance, session2, profile, @"grant", device)[@"ok"] boolValue]);
        CHECK(fails(call(backend, instance, session2, profile, @"open", device), @"NetworkError"));
        NSDictionary *input = @{@"deviceId": deviceId, @"endpointNumber": @1, @"length": @64};
        CHECK(fails(call(backend, instance, session, profile, @"transferIn", input), @"NotFoundError"));
        CHECK(fake_usb_transfer_calls() == 0);
        CHECK([call(backend, instance, session, profile, @"claimInterface", @{@"deviceId": deviceId, @"interfaceNumber": @0})[@"ok"] boolValue]);
        CHECK(fake_usb_claim_calls() == 1);
        NSDictionary *read = call(backend, instance, session, profile, @"transferIn", input);
        CHECK([read[@"result"][@"data"] isEqual:@"AQIDBA=="]);
        CHECK([call(backend, instance, session, profile, @"transferOut", @{@"deviceId": deviceId, @"endpointNumber": @1, @"data": @"AQID"})[@"result"][@"bytesWritten"] isEqual:@3]);
        CHECK([call(backend, instance, session, profile, @"transferIn", @{@"deviceId": deviceId, @"endpointNumber": @2, @"length": @1})[@"result"][@"data"] isEqual:@"AQ=="]);
        CHECK(fails(call(backend, instance, session, profile, @"transferIn", @{@"deviceId": deviceId, @"endpointNumber": @YES, @"length": @1}), @"TypeError"));
        CHECK(fails(call(backend, instance, session, profile, @"transferIn", @{@"deviceId": deviceId, @"endpointNumber": @1, @"length": @1048577}), @"TypeError"));
        CHECK(fails(call(backend, instance, session, profile, @"transferIn", @{@"deviceId": deviceId, @"endpointNumber": @1, @"length": @1.5}), @"TypeError"));
        CHECK(fails(call(backend, instance, session, profile, @"transferOut", @{@"deviceId": deviceId, @"endpointNumber": @1, @"data": @"???"}), @"TypeError"));
        fake_usb_transfer_result(LIBUSB_ERROR_PIPE);
        CHECK([call(backend, instance, session, profile, @"transferIn", input)[@"result"][@"status"] isEqual:@"stall"]);
        fake_usb_transfer_result(LIBUSB_ERROR_TIMEOUT);
        CHECK(fails(call(backend, instance, session, profile, @"transferIn", input), @"TimeoutError"));
        fake_usb_transfer_result(0);
        CHECK([call(backend, instance, session, profile, @"selectAlternateInterface", @{@"deviceId": deviceId, @"interfaceNumber": @0, @"alternateSetting": @1})[@"ok"] boolValue]);
        CHECK(fails(call(backend, instance, session, profile, @"transferIn", input), @"NotFoundError"));
        CHECK([call(backend, instance, session, profile, @"transferIn", @{@"deviceId": deviceId, @"endpointNumber": @3, @"length": @4})[@"ok"] boolValue]);
        NSDictionary *setup = @{@"requestType": @"vendor", @"recipient": @"interface", @"request": @1, @"value": @0, @"index": @0};
        CHECK([call(backend, instance, session, profile, @"controlTransferIn", @{@"deviceId": deviceId, @"setup": setup, @"length": @4})[@"result"][@"data"] isEqual:@"AQIDBA=="]);
        setup = @{@"requestType": @"standard", @"recipient": @"device", @"request": @9, @"value": @2, @"index": @0};
        CHECK(fails(call(backend, instance, session, profile, @"controlTransferOut", @{@"deviceId": deviceId, @"setup": setup, @"data": @""}), @"SecurityError"));
        fake_usb_protected(true);
        CHECK(fails(call(backend, instance, session, profile, @"claimInterface", @{@"deviceId": deviceId, @"interfaceNumber": @1}), @"SecurityError"));
        CHECK(fake_usb_claim_calls() == 1);
        CHECK(fails(call(backend, instance, session, profile, @"reset", device), @"SecurityError"));
        CHECK(fails(call(backend, instance, session, profile, @"selectConfiguration", @{@"deviceId": deviceId, @"configurationValue": @2}), @"SecurityError"));
        setup = @{@"requestType": @"vendor", @"recipient": @"device", @"request": @1, @"value": @0, @"index": @0};
        CHECK(fails(call(backend, instance, session, profile, @"controlTransferIn", @{@"deviceId": deviceId, @"setup": setup, @"length": @4}), @"SecurityError"));
        fake_usb_all_protected(true);
        CHECK(fails(call(backend, instance, @"session-three-123456", profile, @"grant", device), @"SecurityError"));
        fake_usb_all_protected(false);
        CHECK([call(backend, instance, session, profile, @"closeSession", nil)[@"ok"] boolValue]);
        CHECK(fake_usb_open_handles() == 0);
        CHECK([call(backend, instance, session2, profile, @"open", device)[@"ok"] boolValue]);
        // White-box lease clock injection avoids a minute-long test and production test hooks.
        for (id sessionObject in [[backend valueForKey:@"sessions"] allValues]) [sessionObject setValue:@(-60) forKey:@"lastSeen"];
        CHECK(fails(call(backend, instance, session2, profile, @"heartbeat", nil), @"InvalidStateError"));
        CHECK(fake_usb_open_handles() == 0);
        CHECK([call(backend, instance, session, profile, @"grant", device)[@"ok"] boolValue]);
        CHECK([call(backend, instance, session, profile, @"open", device)[@"ok"] boolValue]);
        fake_usb_connected(false);
        CHECK([call(backend, instance, session, profile, @"getDevices", nil)[@"result"] count] == 0);
        CHECK(fake_usb_open_handles() == 0);
        CHECK(fake_usb_ref_balance() == 0);
        fake_usb_connected(true);
        enumeration = [backend handleMessage:@{@"version": @1, @"op": @"enumerate"} profile:profile];
        CHECK(![enumeration[@"result"][0][@"id"] isEqual:deviceId]);
        CHECK(fails(call(backend, instance, session, profile, @"open", device), @"NotFoundError"));
        backend = nil;
        CHECK(fake_usb_ref_balance() == 0);
        fprintf(stdout, "Native fake-USB tests passed (%lu assertions).\n", (unsigned long)assertions);
    }
    return 0;
}
