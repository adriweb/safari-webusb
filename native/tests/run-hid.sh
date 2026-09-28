#!/bin/sh
# Pure descriptor fixtures and fake IOKit: does not inspect/open physical HID.
set -eu
NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/safari-hid-native-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$NATIVE_DIR/HIDReportDescriptor.m" "$NATIVE_DIR/tests/HIDDescriptorTests.m" \
    -framework Foundation -o "$TEST_BUILD_DIR/HIDDescriptorTests"
"$TEST_BUILD_DIR/HIDDescriptorTests"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    -DHID_REPORT_GUARD_SECONDS=0.2 \
    "$NATIVE_DIR/HIDReportDescriptor.m" "$NATIVE_DIR/HIDBackend.m" "$NATIVE_DIR/tests/HIDBackendTests.m" \
    -framework Foundation -framework IOKit -o "$TEST_BUILD_DIR/HIDBackendTests"
"$TEST_BUILD_DIR/HIDBackendTests"
