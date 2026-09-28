#import "DevicePermissionStore.h"

static BOOL PermissionString(id value, NSUInteger limit) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= limit;
}
static BOOL PermissionRecord(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *record = value;
    return PermissionString(record[@"id"], 64) && PermissionString(record[@"profile"], 256) &&
        PermissionString(record[@"origin"], 2048) && PermissionString(record[@"identity"], 4096) &&
        PermissionString(record[@"name"], 512) && [@[@"usb", @"serial", @"hid"] containsObject:record[@"kind"]] &&
        [record[@"durable"] isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)record[@"durable"]) == CFBooleanGetTypeID();
}
@interface DevicePermissionStore ()
@property(nonatomic) NSURL *url;
@property(nonatomic) NSMutableArray<NSDictionary *> *records;
@end
@implementation DevicePermissionStore
+ (NSURL *)defaultURL {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:@"SafariWebUSB" isDirectory:YES] URLByAppendingPathComponent:@"permissions.json"];
}
- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _url = url; _records = [NSMutableArray array];
        NSDictionary *attributes = url ? [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil] : nil;
        if ([attributes[NSFileSize] unsignedLongLongValue] <= 4 * 1024 * 1024) {
            NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:nil] : nil;
            NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([root isKindOfClass:NSDictionary.class] && [root[@"version"] isKindOfClass:NSNumber.class] &&
                CFGetTypeID((__bridge CFTypeRef)root[@"version"]) != CFBooleanGetTypeID() && [root[@"version"] isEqual:@1] &&
                [root[@"permissions"] isKindOfClass:NSArray.class] && [root[@"permissions"] count] <= 4096) {
                // Corruption fails closed; do not retain a partially validated store.
                NSMutableSet *ids = [NSMutableSet set], *scopes = [NSMutableSet set]; BOOL valid = YES;
                for (id record in root[@"permissions"]) {
                    if (!PermissionRecord(record)) { valid = NO; break; }
                    NSData *scope = [NSJSONSerialization dataWithJSONObject:@[record[@"profile"], record[@"origin"], record[@"kind"], record[@"identity"]] options:0 error:nil];
                    if ([ids containsObject:record[@"id"]] || [scopes containsObject:scope]) { valid = NO; break; }
                    [ids addObject:record[@"id"]]; [scopes addObject:scope];
                }
                if (valid) [_records addObjectsFromArray:root[@"permissions"]];
            }
        }
    }
    return self;
}
- (NSArray<NSDictionary *> *)recordsForProfile:(NSString *)profile {
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *record in self.records) if ([record[@"profile"] isEqual:profile]) [result addObject:record];
    return result;
}
- (NSDictionary *)recordForProfile:(NSString *)profile origin:(NSString *)origin kind:(NSString *)kind identity:(NSString *)identity {
    for (NSDictionary *record in self.records) if ([record[@"profile"] isEqual:profile] && [record[@"origin"] isEqual:origin] &&
        [record[@"kind"] isEqual:kind] && [record[@"identity"] isEqual:identity]) return record;
    return nil;
}
- (BOOL)writeRecords:(NSArray *)records error:(NSError **)error {
    if (!self.url) return YES; // Explicitly injected in-memory store for tests.
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version":@1, @"permissions":records} options:NSJSONWritingSortedKeys error:error];
    if (!data || data.length > 4 * 1024 * 1024) return NO;
    if (![NSFileManager.defaultManager createDirectoryAtURL:[self.url URLByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    if (![data writeToURL:self.url options:NSDataWritingAtomic error:error]) return NO;
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.url.path error:nil];
    return YES;
}
- (NSDictionary *)rememberProfile:(NSString *)profile origin:(NSString *)origin kind:(NSString *)kind identity:(NSString *)identity name:(NSString *)name durable:(BOOL)durable error:(NSError **)error {
    NSDictionary *existing = [self recordForProfile:profile origin:origin kind:kind identity:identity];
    if (existing) return existing;
    NSDictionary *record = @{@"id":NSUUID.UUID.UUIDString, @"profile":profile, @"origin":origin, @"kind":kind,
        @"identity":identity, @"name":name, @"durable":@(durable)};
    if (!PermissionRecord(record) || self.records.count >= 4096 || [self recordsForProfile:profile].count >= 512) {
        if (error) *error = [NSError errorWithDomain:@"SafariDevicePermissions" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The saved device permission limit was reached."}];
        return nil;
    }
    NSMutableArray *next = [self.records mutableCopy]; [next addObject:record];
    if (![self writeRecords:next error:error]) return nil;
    self.records = next;
    return record;
}
- (BOOL)removeIDs:(NSArray<NSString *> *)identifiers profile:(NSString *)profile error:(NSError **)error {
    NSMutableArray *next = [self.records mutableCopy];
    NSIndexSet *indexes = [next indexesOfObjectsPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        return [record[@"profile"] isEqual:profile] && [identifiers containsObject:record[@"id"]];
    }];
    if (!indexes.count) return YES;
    [next removeObjectsAtIndexes:indexes];
    if (![self writeRecords:next error:error]) return NO;
    self.records = next; return YES;
}
@end
