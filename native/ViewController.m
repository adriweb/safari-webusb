#import "ViewController.h"
#import "AppDelegate.h"
#import <SafariServices/SafariServices.h>
#import <WebKit/WebKit.h>

static NSString * const extensionBundleIdentifier = @"org.webtilp.safariwebusb.Extension";
@interface AppDelegate (USBTransportStatus)
- (NSString *)usbTransportStatus;
@end
@interface ViewController () <WKNavigationDelegate, WKScriptMessageHandler>
@property(nonatomic) IBOutlet WKWebView *webView;
@end

@implementation ViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.webView.navigationDelegate = self;
    [self.webView.configuration.userContentController addScriptMessageHandler:self name:@"controller"];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(transportStatusChanged:) name:@"USBTransportStatusDidChange" object:nil];
    [self.webView loadFileURL:[NSBundle.mainBundle URLForResource:@"Main" withExtension:@"html"] allowingReadAccessToURL:NSBundle.mainBundle.resourceURL];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)showStatus:(NSString *)status {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@[status ?: @"Starting Safari WebUSB…"] options:0 error:NULL];
    NSString *argument = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    NSString *script = [NSString stringWithFormat:@"(() => { let p = document.getElementById('usb-transport-status'); if (!p) { p = document.createElement('p'); p.id = 'usb-transport-status'; document.body.appendChild(p); } p.textContent = (%@)[0]; document.querySelectorAll('button').forEach(b => { if (b.textContent.includes('Safari')) b.textContent = 'Open Safari Settings…'; }); })()", argument];
    [self.webView evaluateJavaScript:script completionHandler:nil];
}
- (void)transportStatusChanged:(NSNotification *)notification {
    [self showStatus:notification.userInfo[@"status"]];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)navigation;
    [self showStatus:[(AppDelegate *)NSApplication.sharedApplication.delegate usbTransportStatus]];
    [SFSafariExtensionManager getStateOfSafariExtensionWithIdentifier:extensionBundleIdentifier completionHandler:^(SFSafariExtensionState *state, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (state) {
                [webView evaluateJavaScript:[NSString stringWithFormat:@"show(%@, true); document.querySelector('.open-preferences').textContent = 'Open Safari Settings…';", state.isEnabled ? @"true" : @"false"] completionHandler:nil];
            } else if (error) {
                [self showStatus:@"Open Safari Settings and enable Safari WebUSB, then reload your website."];
            }
        });
    }];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    (void)controller;
    if (!message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSString.class] || ![message.body isEqualToString:@"open-preferences"]) return;
    [SFSafariApplication showPreferencesForExtensionWithIdentifier:extensionBundleIdentifier completionHandler:^(NSError *error) {
        if (!error) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showStatus:@"Open Safari > Settings > Extensions and enable Safari WebUSB."];
        });
    }];
}
@end
