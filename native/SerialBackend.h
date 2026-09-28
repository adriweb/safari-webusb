#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Session identifiers are namespaced and authenticated by DeviceBackend.
/// Input is demand-driven: each read grants credit for exactly one bounded chunk.
@interface SerialBackend : NSObject
+ (instancetype)sharedBackend;
/// Native-only permission matching inventory; completion runs on the backend queue.
- (void)permissionDevicesWithCompletion:(void (^)(NSArray<NSDictionary *> *records))completion;
@property (atomic, copy, nullable) void (^eventHandler)(NSString *session, NSDictionary *event);
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session
             completion:(void (^)(NSDictionary *response))completion;
- (void)closeSession:(NSString *)session;
@end

NS_ASSUME_NONNULL_END
