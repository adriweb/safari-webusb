#import "AppDelegate.h"
#import "USBLoopbackServer.h"
#import "USBTransportAuth.h"

@interface AppDelegate ()
@property(nonatomic) USBLoopbackServer *usbServer;
@property(nonatomic, copy) NSString *usbTransportStatus;
@end

@implementation AppDelegate
- (void)updateUSBStatus:(NSString *)status {
    self.usbTransportStatus = status;
    [NSNotificationCenter.defaultCenter postNotificationName:@"USBTransportStatusDidChange" object:self userInfo:@{@"status":status}];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    if (!USBTransportHasSharedGroup()) {
        [self updateUSBStatus:@"This local build uses the compatibility connection. Enable Safari WebUSB in Safari Settings to get started."];
        return;
    }
    [self updateUSBStatus:@"Starting the USB connection…"];
    self.usbServer = [USBLoopbackServer new];
    [self.usbServer startWithCompletion:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateUSBStatus:error ? [NSString stringWithFormat:@"USB connection unavailable: %@", error.localizedDescription] :
                @"Safari WebUSB is running. Keep this app running while using USB devices in Safari. You can close this window."];
        });
    }];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    if (!visible) [sender.windows.firstObject makeKeyAndOrderFront:self];
    return YES;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.usbServer stop];
}
@end
