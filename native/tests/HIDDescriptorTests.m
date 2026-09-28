#import "../HIDReportDescriptor.h"
#import <stdlib.h>

static unsigned checks;
static void Check(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { NSLog(@"FAIL: %@", message); exit(1); }
}
static NSData *Hex(NSString *text) {
    NSMutableData *data = [NSMutableData data];
    for (NSString *part in [text componentsSeparatedByString:@" "]) {
        if (!part.length) continue;
        uint8_t value = (uint8_t)strtoul(part.UTF8String, NULL, 16); [data appendBytes:&value length:1];
    }
    return data;
}
static NSDictionary *Parse(NSString *text) { return HIDParseReportDescriptor(Hex(text), NULL); }
int main(void) { @autoreleasepool {
    // HP Prime-style 64-byte vendor-defined reports; report-ID zero has no
    // prefix byte and descriptors report the full useful payload size.
    NSString *prime = @"06 00 ff 09 01 a1 01 15 00 26 ff 00 75 08 95 40 09 01 81 02 09 01 91 02 c0";
    NSDictionary *parsed = Parse(prime);
    Check(parsed != nil, @"vendor calculator descriptor allowed");
    Check([parsed[@"reportLengths"][@"input"][@0] intValue] == 64, @"Prime input report length");
    Check([parsed[@"reportLengths"][@"output"][@0] intValue] == 64, @"Prime output report length");
    Check([parsed[@"numberedReports"] isEqual:@NO], @"unnumbered report metadata");
    NSDictionary *collection = parsed[@"collections"][0];
    Check([collection[@"usagePage"] intValue] == 0xff00 && [collection[@"usage"] intValue] == 1, @"collection usage");
    NSDictionary *item = collection[@"inputReports"][0][@"items"][0];
    Check([item[@"reportSize"] intValue] == 8 && [item[@"reportCount"] intValue] == 64, @"report items for WebTiLP");
    Check([item[@"logicalMaximum"] intValue] == 255 && [item[@"isAbsolute"] isEqual:@YES] && [item[@"isArray"] isEqual:@NO], @"report field metadata");
    Check(HIDDeviceIsBlocked(0x1050, 0x0407), @"Yubikey denied including vendor interface");
    Check(HIDDeviceIsBlocked(0x18d1, 0x5026), @"Titan token denied");
    Check(!HIDDeviceIsBlocked(0x03f0, 0x2441), @"HP Prime vendor allowed");
    NSDictionary *numbered = Parse(@"06 00 ff 09 01 a1 01 85 03 75 08 95 04 15 80 25 7f 09 02 b1 02 c0");
    Check([numbered[@"reportLengths"][@"feature"][@3] intValue] == 4, @"feature length excludes ID");
    Check([numbered[@"numberedReports"] isEqual:@YES], @"numbered report metadata");
    item = numbered[@"collections"][0][@"featureReports"][0][@"items"][0];
    Check([item[@"logicalMinimum"] intValue] == -128 && [item[@"logicalMaximum"] intValue] == 127, @"signed bounds");
    NSDictionary *nested = Parse(@"06 00 ff 09 01 a1 01 75 03 95 03 09 01 81 02 09 02 a1 00 75 07 95 01 09 02 81 02 c0 c0");
    Check([nested[@"reportLengths"][@"input"][@0] intValue] == 2, @"report accumulates bits across nested collections");
    Check([nested[@"collections"][0][@"children"] count] == 1, @"child collections preserved");
    NSDictionary *pushed = Parse(@"06 00 ff 09 01 a1 01 75 08 95 01 a4 95 02 09 01 81 02 b4 09 01 91 02 c0");
    Check([pushed[@"reportLengths"][@"input"][@0] intValue] == 2 && [pushed[@"reportLengths"][@"output"][@0] intValue] == 1, @"global push and pop");
    NSArray *bad = @[
        @"", @"06 00", @"fe 00 00", @"c0", @"b4", @"05 01 09 06 a1 01 75 08 95 01 81 02 c0", // keyboard
        @"05 01 09 02 a1 01 75 08 95 01 81 02 c0", // mouse
        @"06 d0 f1 09 01 a1 01 75 08 95 01 81 02 c0", // FIDO
        @"05 0c 09 01 a1 01 75 08 95 01 81 02 c0", // consumer
        @"06 00 ff 09 01 a1 01 05 07 75 08 95 01 81 02 c0", // protected fields with missing usage
        @"06 00 ff 09 01 a1 01 05 01 19 00 29 ff 75 08 95 01 81 02 c0", // hidden keyboard range
        @"06 00 ff 09 01 a1 01 75 08 95 01 81 02 85 01 91 02 c0", // mixed IDs
        @"06 00 ff 09 01 a1 01 85 00 75 08 95 01 81 02 c0", // zero explicit ID
        @"06 00 ff 09 01 a1 01 77 ff ff ff ff 95 01 81 02 c0", // giant field
        @"06 00 ff 09 01 a1 01 75 08 95 01 81 02", // unterminated collection
        @"06 00 ff 09 01 a1 01 75 08 95 01 19 02 29 01 81 02 c0", // reversed usage range
        @"06 00 ff 09 01 a1 01 75 08 95 01 a9 01 81 02 c0", // delimiter unsupported
        @"06 00 ff 09 01 a1 01 c0", // no reports
        @"06 00 ff 09 01 a1 01 75 00 95 01 81 02 c0" // zero bit count
    ];
    for (NSString *descriptor in bad) Check(Parse(descriptor) == nil, [@"fail closed: " stringByAppendingString:descriptor]);
    // Deterministic malformed descriptor fuzzing exercises truncations and
    // unknown encodings without accessing HID hardware.
    NSData *fixture = Hex(prime);
    for (NSUInteger i = 0; i < fixture.length; i++) {
        NSString *error = nil;
        Check(HIDParseReportDescriptor([fixture subdataWithRange:NSMakeRange(0, i)], &error) == nil, @"all incomplete prefixes rejected");
        Check(error.length > 0, @"parse errors are explanatory");
    }
    NSLog(@"HID descriptor tests: %u assertions passed", checks);
} return 0; }
