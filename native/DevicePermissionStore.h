#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Called only on the device router's queue. Identity and profile never leave native code.
@interface DevicePermissionStore : NSObject
- (instancetype)initWithURL:(nullable NSURL *)url;
+ (NSURL *)defaultURL;
- (NSArray<NSDictionary *> *)recordsForProfile:(NSString *)profile;
- (nullable NSDictionary *)recordForProfile:(NSString *)profile origin:(NSString *)origin kind:(NSString *)kind identity:(NSString *)identity;
- (nullable NSDictionary *)rememberProfile:(NSString *)profile origin:(NSString *)origin kind:(NSString *)kind identity:(NSString *)identity name:(NSString *)name durable:(BOOL)durable error:(NSError **)error;
- (BOOL)removeIDs:(NSArray<NSString *> *)identifiers profile:(NSString *)profile error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
