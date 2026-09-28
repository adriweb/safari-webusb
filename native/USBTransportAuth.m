#import "USBTransportAuth.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonHMAC.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <math.h>

static const NSTimeInterval USBTransportTokenLifetime = 30;
static NSString * const USBTransportEndpointName = @"native-transport.json";
static NSError *USBTransportError(NSString *message) {
    return [NSError errorWithDomain:@"org.webtilp.safariwebusb.transport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static NSDictionary *USBTransportFailure(NSString *name, NSString *message) {
    return @{@"ok":@NO, @"error":@{@"name":name, @"message":message}};
}
static BOOL USBTransportString(id value, NSUInteger maximum) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= maximum;
}
static BOOL USBTransportUUID(id value) {
    return USBTransportString(value, 36) && [[NSUUID alloc] initWithUUIDString:value] != nil;
}
static BOOL USBTransportNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static BOOL USBTransportOrigin(id origin) {
    if (!USBTransportString(origin, 80)) return NO;
    NSString *prefix = @"safari-web-extension://";
    if (![origin hasPrefix:prefix]) return NO;
    NSString *host = [origin substringFromIndex:prefix.length];
    NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:host];
    return uuid && [host isEqualToString:uuid.UUIDString.lowercaseString];
}
static NSData *USBTransportSecret(id encoded) {
    if (!USBTransportString(encoded, 64)) return nil;
    NSData *secret = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    return secret.length == 32 ? secret : nil;
}
BOOL USBTransportConstantEqual(NSString *a, NSString *b) {
    if (![a isKindOfClass:NSString.class] || ![b isKindOfClass:NSString.class]) return NO;
    NSData *left = [a dataUsingEncoding:NSUTF8StringEncoding], *right = [b dataUsingEncoding:NSUTF8StringEncoding];
    if (left.length != right.length) return NO; // Length is not secret.
    const uint8_t *x = left.bytes, *y = right.bytes;
    volatile uint8_t difference = 0;
    for (NSUInteger i = 0; i < left.length; i++) difference |= x[i] ^ y[i];
    return difference == 0;
}
NSString *USBTransportProof(NSString *base64Key, NSString *message) {
    NSData *key = USBTransportSecret(base64Key);
    if (!key || ![message isKindOfClass:NSString.class]) return nil;
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, data.bytes, data.length, digest);
    return [[NSData dataWithBytes:digest length:sizeof(digest)] base64EncodedStringWithOptions:0];
}
static NSString *USBTransportGroupIdentifier(void) {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return nil;
    id groups = CFBridgingRelease(SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.security.application-groups"), NULL));
    CFRelease(task);
    if (![groups isKindOfClass:NSArray.class]) return nil;
    SecCodeRef code = NULL;
    CFDictionaryRef information = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess) return nil;
    OSStatus status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    CFRelease(code);
    if (status != errSecSuccess || !information) return nil;
    NSDictionary *signature = CFBridgingRelease(information);
    NSString *team = signature[(__bridge NSString *)kSecCodeInfoTeamIdentifier];
    if (!USBTransportString(team, 64)) return nil;
    NSString *group = [team stringByAppendingString:@".org.webtilp.safariwebusb"];
    if (![groups containsObject:group]) return nil;
    return group;
}
static NSURL *USBTransportGroupURL(void) {
    NSString *group = USBTransportGroupIdentifier();
    return group ? [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group] : nil;
}
BOOL USBTransportHasSharedGroup(void) { return USBTransportGroupIdentifier() != nil; }
static BOOL USBTransportEndpointValid(id endpoint) {
    if (![endpoint isKindOfClass:NSDictionary.class]) return NO;
    id port = endpoint[@"port"];
    return USBTransportNumber(endpoint[@"version"]) && [endpoint[@"version"] isEqual:@1] && USBTransportUUID(endpoint[@"instance"]) && USBTransportSecret(endpoint[@"secret"]) &&
        USBTransportNumber(port) && [port doubleValue] == [port unsignedIntegerValue] && [port unsignedIntegerValue] > 0 && [port unsignedIntegerValue] <= UINT16_MAX;
}
static NSDictionary *USBReadTransportEndpoint(NSURL *directory) {
    NSURL *url = [directory URLByAppendingPathComponent:USBTransportEndpointName];
    int fd = open(url.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077) || st.st_size <= 0 || st.st_size > 8192) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t count = read(fd, (uint8_t *)data.mutableBytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        offset += (NSUInteger)count;
    }
    close(fd);
    id endpoint = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return USBTransportEndpointValid(endpoint) ? endpoint : nil;
}
static int USBTransportLock(NSURL *directory) {
    NSURL *lock = [directory URLByAppendingPathComponent:@"native-transport.lock"];
    int fd = open(lock.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077) || flock(fd, LOCK_EX)) { close(fd); return -1; }
    return fd;
}
NSDictionary *USBPublishTransportEndpoint(uint16_t port, NSError **error) {
    NSURL *directory = USBTransportGroupURL();
    if (!port || !directory) {
        if (error) *error = USBTransportError(@"A signed App Group is required for the fast USB connection. Rebuild with your Apple team or use the compatibility transport.");
        return nil;
    }
    uint8_t random[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(random), random) != errSecSuccess) {
        if (error) *error = USBTransportError(@"Could not create the USB connection credential. Restart Safari WebUSB.");
        return nil;
    }
    NSDictionary *endpoint = @{@"version":@1, @"instance":NSUUID.UUID.UUIDString, @"port":@(port),
        @"secret":[[NSData dataWithBytes:random length:sizeof(random)] base64EncodedStringWithOptions:0]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:endpoint options:0 error:NULL];
    int lock = USBTransportLock(directory);
    if (lock < 0) { if (error) *error = USBTransportError(@"Could not open the shared USB connection state. Restart Safari WebUSB."); return nil; }
    NSString *temporaryName = [@"native-transport-" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSURL *temporary = [directory URLByAppendingPathComponent:temporaryName];
    NSURL *destination = [directory URLByAppendingPathComponent:USBTransportEndpointName];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    BOOL success = fd >= 0;
    NSUInteger offset = 0;
    while (success && offset < data.length) {
        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { success = NO; break; }
        offset += (NSUInteger)count;
    }
    if (fd >= 0) { if (fsync(fd)) success = NO; if (close(fd)) success = NO; }
    if (success) success = rename(temporary.fileSystemRepresentation, destination.fileSystemRepresentation) == 0;
    if (!success) unlink(temporary.fileSystemRepresentation);
    flock(lock, LOCK_UN); close(lock);
    if (!success) { if (error) *error = USBTransportError(@"Could not publish the USB connection. Restart Safari WebUSB."); return nil; }
    return endpoint;
}
void USBRemoveTransportEndpoint(NSDictionary *endpoint) {
    if (!USBTransportEndpointValid(endpoint)) return;
    NSURL *directory = USBTransportGroupURL();
    if (!directory) return;
    int lock = USBTransportLock(directory);
    if (lock < 0) return;
    NSDictionary *current = USBReadTransportEndpoint(directory);
    if ([current[@"instance"] isEqual:endpoint[@"instance"]])
        unlink([directory URLByAppendingPathComponent:USBTransportEndpointName].fileSystemRepresentation);
    flock(lock, LOCK_UN); close(lock);
}
static NSDictionary *USBMakeTransportBootstrap(NSString *profile, NSString *origin, NSDictionary *endpoint) {
    if (!USBTransportString(profile, 256) || !USBTransportOrigin(origin) || !USBTransportEndpointValid(endpoint))
        return USBTransportFailure(@"SecurityError", @"Invalid USB connection bootstrap request.");
    NSTimeInterval issued = NSDate.date.timeIntervalSince1970;
    NSDictionary *claims = @{@"version":@1, @"instance":endpoint[@"instance"], @"profile":profile, @"origin":origin,
        @"nonce":NSUUID.UUID.UUIDString, @"issued":@(issued), @"expires":@(issued + USBTransportTokenLifetime)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:claims options:NSJSONWritingSortedKeys error:NULL];
    NSString *payload = [data base64EncodedStringWithOptions:0];
    NSString *signature = USBTransportProof(endpoint[@"secret"], [@"token:" stringByAppendingString:payload]);
    NSString *key = USBTransportProof(endpoint[@"secret"], [@"connection:" stringByAppendingString:payload]);
    return @{@"ok":@YES, @"url":[NSString stringWithFormat:@"ws://127.0.0.1:%@/", endpoint[@"port"]],
        @"token":[NSString stringWithFormat:@"%@.%@", payload, signature], @"key":key};
}
NSDictionary *USBTransportBootstrap(NSString *profile, NSString *origin) {
    if (!USBTransportString(profile, 256) || !USBTransportOrigin(origin))
        return USBTransportFailure(@"SecurityError", @"Invalid USB connection bootstrap request.");
    NSString *group = USBTransportGroupIdentifier();
    if (!group) return USBTransportFailure(@"NotSupportedError", @"This build has no signed App Group; use the compatibility transport.");
    NSURL *directory = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:group];
    if (!directory) return USBTransportFailure(@"InvalidStateError", @"The signed USB connection state is unavailable. Restart Safari WebUSB and Safari, then reload this website and choose your USB device again.");
    NSDictionary *endpoint = USBReadTransportEndpoint(directory);
    if (!endpoint) return USBTransportFailure(@"InvalidStateError", @"Open Safari WebUSB and keep it running, then reload this website and choose your USB device again.");
    return USBMakeTransportBootstrap(profile, origin, endpoint);
}
NSDictionary *USBVerifyTransportToken(NSString *token, NSString *origin, NSDictionary *endpoint) {
    if (!USBTransportString(token, 4096) || !USBTransportOrigin(origin) || !USBTransportEndpointValid(endpoint)) return nil;
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count != 2) return nil;
    NSString *payload = parts[0];
    NSString *expected = USBTransportProof(endpoint[@"secret"], [@"token:" stringByAppendingString:payload]);
    if (!USBTransportConstantEqual(expected, parts[1])) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data || ![payload isEqual:[data base64EncodedStringWithOptions:0]]) return nil;
    id claims = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![claims isKindOfClass:NSDictionary.class] || !USBTransportNumber(claims[@"version"]) || ![claims[@"version"] isEqual:@1] ||
        ![claims[@"instance"] isEqual:endpoint[@"instance"]] || ![claims[@"origin"] isEqual:origin] ||
        !USBTransportString(claims[@"profile"], 256) || !USBTransportUUID(claims[@"nonce"]) ||
        !USBTransportNumber(claims[@"issued"]) || !USBTransportNumber(claims[@"expires"])) return nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970, issued = [claims[@"issued"] doubleValue], expires = [claims[@"expires"] doubleValue];
    if (issued > now + 1 || expires <= now || expires <= issued || expires - issued > USBTransportTokenLifetime + 0.001 || expires > now + USBTransportTokenLifetime + 1) return nil;
    NSString *key = USBTransportProof(endpoint[@"secret"], [@"connection:" stringByAppendingString:payload]);
    return @{@"profile":claims[@"profile"], @"nonce":claims[@"nonce"], @"expires":claims[@"expires"], @"key":key};
}
