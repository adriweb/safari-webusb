#import "HIDReportDescriptor.h"

static const NSUInteger HIDMaximumReportBytes = 1024 * 1024;

BOOL HIDUsageIsProtected(uint32_t usage) {
    uint32_t page = usage >> 16, id = usage & 0xffff;
    // Conservative whole-device policy. Composite devices containing any of
    // these collections or fields are unavailable, including vendor reports.
    if (page == 0x07 || page == 0x0c || page == 0x0d || page == 0xf1d0) return YES;
    return page == 0x01 && (id == 0x01 || id == 0x02 || id == 0x06 || id == 0x07 || (id >= 0x80 && id <= 0x8f));
}

BOOL HIDDeviceIsBlocked(uint16_t vendor, uint16_t product) {
    // Security tokens can also expose vendor-defined firmware/configuration
    // interfaces. Do not grant those just because they lack a FIDO usage.
    return vendor == 0x1050 || vendor == 0x096e || vendor == 0x20a0 ||
           (vendor == 0x18d1 && product == 0x5026);
}

static int32_t SignedValue(uint32_t value, NSUInteger size) {
    if (size == 1) return (int8_t)value;
    if (size == 2) return (int16_t)value;
    return (int32_t)value;
}
static int UnitNibble(uint32_t unit, unsigned shift) {
    unsigned value = (unit >> shift) & 15;
    return value & 8 ? (int)value - 16 : (int)value;
}
static NSDictionary *ParseFailure(NSString **error, NSString *message) {
    if (error) *error = message;
    return nil;
}

NSDictionary *HIDParseReportDescriptor(NSData *data, NSString **error) {
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > 65536)
        return ParseFailure(error, @"Missing or oversized HID report descriptor.");
    NSMutableArray *roots = [NSMutableArray array], *collections = [NSMutableArray array], *stack = [NSMutableArray array];
    NSMutableDictionary *global = [@{@"usagePage": @0, @"logicalMinimum": @0, @"logicalMaximum": @0,
        @"physicalMinimum": @0, @"physicalMaximum": @0, @"unitExponent": @0, @"unit": @0,
        @"reportSize": @0, @"reportCount": @0, @"reportId": @0} mutableCopy];
    NSMutableArray *usages = [NSMutableArray array];
    NSNumber *usageMin = nil, *usageMax = nil;
    NSMutableDictionary *lengths = [@{@"input": [NSMutableDictionary dictionary], @"output": [NSMutableDictionary dictionary],
                                    @"feature": [NSMutableDictionary dictionary]} mutableCopy];
    BOOL numbered = NO, unnumbered = NO;
    NSUInteger items = 0;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger cursor = 0; cursor < data.length;) {
        uint8_t prefix = bytes[cursor++];
        if (prefix == 0xfe) return ParseFailure(error, @"Long HID descriptor items are unsupported.");
        NSUInteger size = prefix & 3; if (size == 3) size = 4;
        if (cursor + size > data.length) return ParseFailure(error, @"Truncated HID descriptor item.");
        uint32_t value = 0; for (NSUInteger i = 0; i < size; i++) value |= (uint32_t)bytes[cursor++] << (8 * i);
        unsigned type = (prefix >> 2) & 3, tag = prefix >> 4;
        if (type == 1) {
            switch (tag) {
                case 0:
                    if (value > 65535) return ParseFailure(error, @"Invalid HID usage page.");
                    if (HIDUsageIsProtected(value << 16)) return ParseFailure(error, @"Device contains a protected HID usage page.");
                    global[@"usagePage"] = @(value); break;
                case 1: global[@"logicalMinimum"] = @(SignedValue(value, size)); break;
                case 2: global[@"logicalMaximum"] = [global[@"logicalMinimum"] longLongValue] < 0 ? @(SignedValue(value, size)) : @(value); break;
                case 3: global[@"physicalMinimum"] = @(SignedValue(value, size)); break;
                case 4: global[@"physicalMaximum"] = [global[@"physicalMinimum"] longLongValue] < 0 ? @(SignedValue(value, size)) : @(value); break;
                case 5: global[@"unitExponent"] = @(UnitNibble(value, 0)); break;
                case 6: global[@"unit"] = @(value); break;
                case 7: if (value > HIDMaximumReportBytes * 8) return ParseFailure(error, @"Oversized HID report field."); global[@"reportSize"] = @(value); break;
                case 8: if (!value || value > 255) return ParseFailure(error, @"Invalid HID report ID."); global[@"reportId"] = @(value); break;
                case 9: if (value > HIDMaximumReportBytes * 8) return ParseFailure(error, @"Oversized HID report count."); global[@"reportCount"] = @(value); break;
                case 10: if (size || stack.count >= 32) return ParseFailure(error, @"Invalid HID global push."); [stack addObject:[global copy]]; break;
                case 11: if (size || !stack.count) return ParseFailure(error, @"Invalid HID global pop."); global = [stack.lastObject mutableCopy]; [stack removeLastObject]; break;
                default: return ParseFailure(error, @"Unsupported HID global item.");
            }
        } else if (type == 2) {
            if (tag <= 2) {
                uint32_t usage = size == 4 ? value : ([global[@"usagePage"] unsignedIntValue] << 16) | value;
                if (HIDUsageIsProtected(usage)) return ParseFailure(error, @"Device contains a protected HID usage.");
                if (tag == 0) { if (usages.count >= 4096) return ParseFailure(error, @"Too many HID usages."); [usages addObject:@(usage)]; }
                else if (tag == 1) usageMin = @(usage); else usageMax = @(usage);
            } else if (tag == 10) return ParseFailure(error, @"HID usage delimiters are unsupported.");
            else if (!(tag >= 3 && tag <= 9)) return ParseFailure(error, @"Unsupported HID local item.");
        } else if (type == 0) {
            if (usageMin || usageMax) {
                if (!usageMin || !usageMax || usageMin.unsignedIntValue > usageMax.unsignedIntValue ||
                    (usageMin.unsignedIntValue >> 16) != (usageMax.unsignedIntValue >> 16))
                    return ParseFailure(error, @"Invalid HID usage range.");
                // Check every protected generic-desktop usage even if only the
                // endpoints of a range appear in the descriptor.
                if ((usageMin.unsignedIntValue >> 16) == 1) {
                    uint32_t lo = usageMin.unsignedIntValue & 65535, hi = usageMax.unsignedIntValue & 65535;
                    if ((lo <= 2 && hi >= 1) || (lo <= 7 && hi >= 6) || (lo <= 0x8f && hi >= 0x80))
                        return ParseFailure(error, @"Device contains a protected HID usage range.");
                }
            }
            if (tag == 10) {
                if (!size || value > 255 || collections.count >= 32 || ++items > 4096)
                    return ParseFailure(error, @"Invalid HID collection.");
                uint32_t usage = usages.count ? [usages[0] unsignedIntValue] : usageMin.unsignedIntValue;
                NSMutableDictionary *collection = [@{@"usagePage": @(usage >> 16), @"usage": @(usage & 65535), @"type": @(value),
                    @"children": [NSMutableArray array], @"inputReports": [NSMutableArray array],
                    @"outputReports": [NSMutableArray array], @"featureReports": [NSMutableArray array]} mutableCopy];
                if (collections.count) [collections.lastObject[@"children"] addObject:collection]; else [roots addObject:collection];
                [collections addObject:collection];
            } else if (tag == 12) {
                if (size || !collections.count) return ParseFailure(error, @"Unbalanced HID collection end.");
                [collections removeLastObject];
            } else if (tag == 8 || tag == 9 || tag == 11) {
                if (!collections.count || !size || ++items > 4096) return ParseFailure(error, @"Invalid HID report item.");
                NSNumber *reportId = global[@"reportId"];
                if (reportId.unsignedIntValue) numbered = YES; else unnumbered = YES;
                if (numbered && unnumbered) return ParseFailure(error, @"Mixed numbered and unnumbered HID reports.");
                NSString *kind = tag == 8 ? @"input" : tag == 9 ? @"output" : @"feature";
                NSString *reportKey = [kind stringByAppendingString:@"Reports"];
                uint64_t bits = [global[@"reportSize"] unsignedLongLongValue] * [global[@"reportCount"] unsignedLongLongValue];
                uint64_t totalBits = [lengths[kind][reportId] unsignedLongLongValue] + bits;
                if (!bits || totalBits > HIDMaximumReportBytes * 8) return ParseFailure(error, @"Invalid or oversized HID report length.");
                lengths[kind][reportId] = @(totalBits);
                NSMutableArray *reports = collections.lastObject[reportKey];
                NSMutableDictionary *report = nil;
                for (NSMutableDictionary *candidate in reports) if ([candidate[@"reportId"] isEqual:reportId]) { report = candidate; break; }
                if (!report) { report = [@{@"reportId": reportId, @"items": [NSMutableArray array]} mutableCopy]; [reports addObject:report]; }
                uint32_t unit = [global[@"unit"] unsignedIntValue];
                NSArray *unitSystems = @[@"none", @"si-linear", @"si-rotation", @"english-linear", @"english-rotation"];
                NSString *unitSystem = (unit & 15) < unitSystems.count ? unitSystems[unit & 15] : (unit & 15) == 15 ? @"vendor-defined" : @"reserved";
                NSDictionary *item = @{@"isAbsolute": @(!(value & 4)), @"isArray": @(!(value & 2)), @"isBufferedBytes": @((value & 256) != 0),
                    @"isConstant": @((value & 1) != 0), @"isLinear": @(!(value & 16)), @"isRange": @(usageMin != nil),
                    @"isVolatile": @((value & 128) != 0), @"hasNull": @((value & 64) != 0), @"hasPreferredState": @(!(value & 32)), @"wrap": @((value & 8) != 0),
                    @"usages": [usages copy], @"usageMinimum": usageMin ?: @0, @"usageMaximum": usageMax ?: @0,
                    @"reportSize": global[@"reportSize"], @"reportCount": global[@"reportCount"],
                    @"logicalMinimum": global[@"logicalMinimum"], @"logicalMaximum": global[@"logicalMaximum"],
                    @"physicalMinimum": global[@"physicalMinimum"], @"physicalMaximum": global[@"physicalMaximum"],
                    @"unitExponent": global[@"unitExponent"], @"unitSystem": unitSystem,
                    @"unitFactorLengthExponent": @(UnitNibble(unit, 4)), @"unitFactorMassExponent": @(UnitNibble(unit, 8)),
                    @"unitFactorTimeExponent": @(UnitNibble(unit, 12)), @"unitFactorTemperatureExponent": @(UnitNibble(unit, 16)),
                    @"unitFactorCurrentExponent": @(UnitNibble(unit, 20)), @"unitFactorLuminousIntensityExponent": @(UnitNibble(unit, 24))};
                [report[@"items"] addObject:item];
            } else return ParseFailure(error, @"Unsupported HID main item.");
            [usages removeAllObjects]; usageMin = nil; usageMax = nil;
        } else return ParseFailure(error, @"Reserved HID descriptor item.");
    }
    if (collections.count || stack.count || !roots.count) return ParseFailure(error, @"Incomplete HID descriptor.");
    NSUInteger reportCount = 0;
    for (NSString *kind in lengths) for (NSNumber *reportId in [lengths[kind] allKeys]) {
        uint64_t bits = [lengths[kind][reportId] unsignedLongLongValue]; lengths[kind][reportId] = @((bits + 7) / 8); reportCount++;
    }
    if (!reportCount) return ParseFailure(error, @"HID descriptor contains no reports.");
    return @{@"collections": roots, @"reportLengths": lengths, @"numberedReports": @(numbered)};
}
