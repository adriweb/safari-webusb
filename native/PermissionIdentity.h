#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/sysctl.h>

// These keys stay inside the native process and its permission store. Public
// snapshots continue to use random per-attachment IDs, never registry IDs.
NS_INLINE NSString *PermissionIdentityKey(NSArray *components) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:components options:0 error:NULL];
    return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

NS_INLINE BOOL PermissionSerialIsUsable(id serial) {
    return [serial isKindOfClass:NSString.class] && [serial length] > 0 && [serial length] <= 1024 &&
        [[serial stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] > 0;
}

NS_INLINE NSString *PermissionAttachmentIdentity(NSString *api, NSArray *hardware, NSString *attachment, NSString *fallback) {
    static NSString *boot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char value[128] = {0}; size_t size = sizeof(value);
        if (sysctlbyname("kern.bootsessionuuid", value, &size, NULL, 0) == 0 && size > 1 && size <= sizeof(value)) {
            value[sizeof(value) - 1] = 0;
            NSString *candidate = [NSString stringWithUTF8String:value];
            if (candidate && [[NSUUID alloc] initWithUUIDString:candidate]) boot = [@"boot:" stringByAppendingString:candidate];
        }
        // Failure to obtain a boot ID must shorten permission lifetime, never
        // broaden it to an attachment ID which could be reused after reboot.
        if (!boot) boot = [@"process:" stringByAppendingString:NSUUID.UUID.UUIDString];
    });
    return PermissionIdentityKey(@[api, @"attachment", boot, attachment.length ? attachment : fallback, hardware]);
}

NS_INLINE NSString *PermissionDescriptorHash(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < sizeof(digest); ++i) [result appendFormat:@"%02x", digest[i]];
    return result;
}
