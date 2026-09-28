#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An authenticated, loopback-only WebSocket transport for the existing USB API.
/// The containing app owns this server and the backend's USB handles.
@interface USBLoopbackServer : NSObject
- (void)startWithCompletion:(void (^)(NSError * _Nullable error))completion;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
