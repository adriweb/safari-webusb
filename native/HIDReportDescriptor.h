#import <Foundation/Foundation.h>

// Fails closed for malformed/unsupported descriptors and protected HID usages.
// Report lengths exclude the optional report-ID byte.
FOUNDATION_EXPORT NSDictionary *HIDParseReportDescriptor(NSData *data, NSString **error);
FOUNDATION_EXPORT BOOL HIDUsageIsProtected(uint32_t usage);
FOUNDATION_EXPORT BOOL HIDDeviceIsBlocked(uint16_t vendor, uint16_t product);
