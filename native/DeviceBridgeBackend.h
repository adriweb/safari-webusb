#import <Foundation/Foundation.h>
@class DevicePermissionStore;
NS_ASSUME_NONNULL_BEGIN
/// One process instance and document lifetime across the three device APIs.
@interface DeviceBridgeBackend : NSObject
+ (instancetype)sharedBackend;
- (instancetype)initWithPermissionStore:(DevicePermissionStore *)store;
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *profile, NSString *session, NSDictionary *event);
/// Legacy/native-messaging callers have no durable permission namespace.
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *response))completion;
/// permissionProfile is authenticated by the transport; profile is connection-specific.
- (void)handleMessage:(id)message profile:(NSString *)profile permissionProfile:(nullable NSString *)permissionProfile completion:(void (^)(NSDictionary *response))completion;
/// Only the authenticated extension's permission-manager channel may call this.
- (void)handlePermissionMessage:(id)message permissionProfile:(NSString *)permissionProfile completion:(void (^)(NSDictionary *response))completion;
@end
NS_ASSUME_NONNULL_END
