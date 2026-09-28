#import <Foundation/Foundation.h>

@interface HIDBackend : NSObject
+ (instancetype)sharedBackend;
@property(copy) void (^eventHandler)(NSString *session, NSDictionary *event);
- (void)handleOperation:(NSString *)operation args:(NSDictionary *)args session:(NSString *)session
            completion:(void (^)(NSDictionary *response))completion;
- (void)closeSession:(NSString *)session;
@end
