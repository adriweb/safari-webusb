#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// One process instance and document lifetime across the three device APIs.
@interface DeviceBridgeBackend : NSObject
+ (instancetype)sharedBackend;
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *profile, NSString *session, NSDictionary *event);
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *response))completion;
@end
NS_ASSUME_NONNULL_END
