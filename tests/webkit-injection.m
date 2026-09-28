// Runs the actual extension in the installed WebKit engine without changing
// Safari settings. No USB request, chooser, or transfer is performed.
// Build: xcrun clang -fobjc-arc -framework AppKit -framework WebKit \
//          tests/webkit-injection.m -o /tmp/safari-webusb-injection
// Run:   /tmp/safari-webusb-injection "$PWD/extension"
// Requires macOS 15.4+ for the public WKWebExtension embedding API.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

static NSURL *fixtureURL(void) {
    // Only a base URL for loadHTMLString; no request is sent to this host.
    return [NSURL URLWithString:@"https://example.org/safari-webusb-test"];
}

@interface WebUSBInjectionProbe : NSObject <WKNavigationDelegate, WKWebExtensionTab>
@property WKWebView *view;
@property WKWebExtensionController *controller;
@property WKWebExtensionContext *context;
@end

@implementation WebUSBInjectionProbe
- (WKWebView *)webViewForWebExtensionContext:(WKWebExtensionContext *)context {
    return self.view;
}
- (NSURL *)URLForWebExtensionContext:(WKWebExtensionContext *)context {
    return fixtureURL();
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [webView evaluateJavaScript:@"JSON.stringify(window.__firstScriptWebUSB)"
             completionHandler:^(id value, NSError *error) {
        if (error || ![value isKindOfClass:NSString.class]) {
            fprintf(stderr, "Could not inspect the first page script: %s\n", error.description.UTF8String);
            exit(1);
        }
        NSDictionary *observed = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        BOOL passed = [observed[@"secure"] boolValue]
            && [observed[@"usb"] isEqual:@"object"]
            && [observed[@"requestDevice"] isEqual:@"function"]
            && [observed[@"getDevices"] isEqual:@"function"]
            && [observed[@"USBDevice"] isEqual:@"function"]
            && [observed[@"USBConfiguration"] isEqual:@"function"]
            && [observed[@"requestPort"] isEqual:@"function"]
            && [observed[@"SerialPort"] isEqual:@"function"]
            && [observed[@"hidRequestDevice"] isEqual:@"function"]
            && [observed[@"HIDDevice"] isEqual:@"function"];
        printf("First inline page script: %s\n", [value UTF8String]);
        printf("%s: MAIN-world document_start API visibility.\n", passed ? "PASS" : "FAIL");
        exit(passed ? 0 : 1);
    }];
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    fprintf(stderr, "Navigation failed: %s\n", error.description.UTF8String);
    exit(1);
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    [self webView:webView didFailNavigation:navigation withError:error];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: %s /absolute/path/to/extension\n", argv[0]);
            return 2;
        }
        if (@available(macOS 15.4, *)) {
            [NSApplication sharedApplication];
            WebUSBInjectionProbe *probe = [WebUSBInjectionProbe new];
            NSURL *resources = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
            [WKWebExtension extensionWithResourceBaseURL:resources completionHandler:^(WKWebExtension *extension, NSError *error) {
                if (error || extension.errors.count) {
                    fprintf(stderr, "Manifest failed validation: %s %s\n", error.description.UTF8String, extension.errors.description.UTF8String);
                    exit(1);
                }
                printf("Installed WebKit accepted manifest v%.0f with no parse errors.\n", extension.manifestVersion);
                probe.context = [WKWebExtensionContext contextForExtension:extension];
                // Ephemeral storage makes this a private test tab. Granting this
                // flag affects only this context; no Safari preference is changed.
                probe.context.hasAccessToPrivateData = YES;
                [probe.context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forURL:fixtureURL()];
                probe.controller = [[WKWebExtensionController alloc] initWithConfiguration:WKWebExtensionControllerConfiguration.nonPersistentConfiguration];
                NSError *loadError = nil;
                if (![probe.controller loadExtensionContext:probe.context error:&loadError]) {
                    fprintf(stderr, "Extension failed to load: %s\n", loadError.description.UTF8String);
                    exit(1);
                }
                WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
                configuration.webExtensionController = probe.controller;
                configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
                probe.view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600) configuration:configuration];
                probe.view.navigationDelegate = probe;
                [probe.controller didOpenTab:probe];
                // Observe synchronously in the very first document script. A
                // later injection or ISOLATED-world shim cannot make this pass.
                NSString *html = @"<!doctype html><script>window.__firstScriptWebUSB = {"
                    "secure: isSecureContext, usb: typeof navigator.usb, "
                    "requestDevice: typeof navigator.usb?.requestDevice, "
                    "getDevices: typeof navigator.usb?.getDevices, "
                    "USBDevice: typeof USBDevice, USBConfiguration: typeof USBConfiguration, "
                    "requestPort: typeof navigator.serial?.requestPort, SerialPort: typeof SerialPort, "
                    "hidRequestDevice: typeof navigator.hid?.requestDevice, HIDDevice: typeof HIDDevice"
                    "};</script><p>Local in-memory WebUSB injection test.</p>";
                [probe.view loadHTMLString:html baseURL:fixtureURL()];
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                fprintf(stderr, "WebKit injection test timed out.\n");
                exit(1);
            });
            [NSApp run];
        } else {
            fprintf(stderr, "The WebKit embedding test requires macOS 15.4 or newer.\n");
            return 2;
        }
    }
    return 0;
}
