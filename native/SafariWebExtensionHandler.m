#import <SafariServices/SafariServices.h>
#import "USBBackend.h"
#import "USBTransportAuth.h"

@interface SafariWebExtensionHandler : NSObject <NSExtensionRequestHandling>
@end

@implementation SafariWebExtensionHandler
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    // Pace fast replies natively: Safari may throttle background-page timers.
    // Capture the monotonic deadline before USB work, so slow transfers incur
    // no additional pacing delay. Never delay or replay the USB operation itself.
    dispatch_time_t replyDeadline = dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC);
    NSExtensionItem *item = context.inputItems.firstObject;
    id message = [item isKindOfClass:NSExtensionItem.class] ? item.userInfo[SFExtensionMessageKey] : nil;
    NSString *profile = @"legacy-default";
    if (@available(macOS 14.0, *)) {
        id safariProfile = item.userInfo[SFExtensionProfileKey];
        if ([safariProfile isKindOfClass:NSUUID.class]) profile = [safariProfile UUIDString];
        else if ([safariProfile isKindOfClass:NSString.class] && [safariProfile length]) profile = safariProfile;
    }
    // Only privileged extension pages can invoke native messaging. The profile
    // is supplied by Safari, while origin is checked again by the socket host.
    if ([message isKindOfClass:NSDictionary.class] && [message[@"op"] isEqual:@"transportBootstrap"]) {
        id version = message[@"version"];
        id args = message[@"args"];
        NSDictionary *response;
        if ([version isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)version) != CFBooleanGetTypeID() &&
            [version isEqual:@1] && [args isKindOfClass:NSDictionary.class]) {
            response = USBTransportBootstrap(profile, args[@"origin"]);
        } else {
            response = @{@"ok":@NO, @"error":@{@"name":@"TypeError", @"message":@"Invalid USB transport bootstrap request."}};
        }
        dispatch_after(replyDeadline, dispatch_get_main_queue(), ^{
            NSExtensionItem *output = [NSExtensionItem new];
            output.userInfo = @{SFExtensionMessageKey:response};
            [context completeRequestReturningItems:@[output] completionHandler:nil];
        });
        return;
    }
    [[USBBackend sharedBackend] handleMessage:message profile:profile completion:^(NSDictionary *response) {
        dispatch_after(replyDeadline, dispatch_get_main_queue(), ^{
            NSExtensionItem *output = [NSExtensionItem new];
            output.userInfo = @{SFExtensionMessageKey: response};
            [context completeRequestReturningItems:@[output] completionHandler:nil];
        });
    }];
}
@end
