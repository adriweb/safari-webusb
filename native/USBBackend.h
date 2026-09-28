#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// All calls are serialized. The profile comes from Safari, never the page's JSON.
@interface USBBackend : NSObject
+ (instancetype)sharedBackend;
@property(nonatomic, copy, readonly) NSString *instance;
- (NSDictionary *)handleMessage:(id)message profile:(NSString *)profile;
/// Captures the admission deadline before enqueueing; completion runs on the USB queue.
- (void)handleMessage:(id)message profile:(NSString *)profile completion:(void (^)(NSDictionary *response))completion;
@end

NS_ASSUME_NONNULL_END
