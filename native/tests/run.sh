#!/bin/sh
# This test executable links FakeUSB.c instead of libusb: no USB hardware access.
set -eu
NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -n "${LIBUSB_PREFIX:-}" ]; then
    LIBUSB_INCLUDEDIR="$LIBUSB_PREFIX/include"
else
    LIBUSB_INCLUDEDIR=$(pkg-config --variable=includedir libusb-1.0)
fi
TEST_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/safari-webusb-native-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT HUP INT TERM
xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
    -I"$LIBUSB_INCLUDEDIR/libusb-1.0" \
    -c "$NATIVE_DIR/tests/FakeUSB.c" -o "$TEST_BUILD_DIR/FakeUSB.o"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=12.0 \
    -I"$LIBUSB_INCLUDEDIR/libusb-1.0" \
    "$NATIVE_DIR/USBBackend.m" "$NATIVE_DIR/tests/USBBackendTests.m" \
    "$TEST_BUILD_DIR/FakeUSB.o" -framework Foundation -o "$TEST_BUILD_DIR/USBBackendTests"
"$TEST_BUILD_DIR/USBBackendTests"

# Exercise native reply pacing with a fake backend, context, and monotonic clock.
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$NATIVE_DIR/tests/SafariWebExtensionHandlerTests.m" \
    "$NATIVE_DIR/USBTransportAuth.m" \
    -framework Foundation -framework SafariServices -framework Security -o "$TEST_BUILD_DIR/SafariWebExtensionHandlerTests"
"$TEST_BUILD_DIR/SafariWebExtensionHandlerTests"

# HMAC mutual authentication, profile/origin binding, and token expiry.
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$NATIVE_DIR/tests/USBTransportAuthTests.m" \
    -framework Foundation -framework Security -o "$TEST_BUILD_DIR/USBTransportAuthTests"
"$TEST_BUILD_DIR/USBTransportAuthTests"

# Real loopback WebSocket framing/authentication and queue teardown with a fake
# USB backend. No calculator or other USB device is accessed by this test.
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    -DUSB_TRANSPORT_ADMISSION_SECONDS=0.2 \
    "$NATIVE_DIR/USBLoopbackServer.m" "$NATIVE_DIR/tests/USBLoopbackServerTests.m" \
    -framework Foundation -framework Network -o "$TEST_BUILD_DIR/USBLoopbackServerTests"
"$TEST_BUILD_DIR/USBLoopbackServerTests"

# Shared document/profile lifetime and event routing across all APIs.
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$NATIVE_DIR/DeviceBridgeBackend.m" "$NATIVE_DIR/DevicePermissionStore.m" "$NATIVE_DIR/tests/DeviceBridgeBackendTests.m" \
    -framework Foundation -o "$TEST_BUILD_DIR/DeviceBridgeBackendTests"
"$TEST_BUILD_DIR/DeviceBridgeBackendTests"

"$NATIVE_DIR/tests/run-serial.sh"
"$NATIVE_DIR/tests/run-hid.sh"

# Atomic permission persistence, scope isolation, validation and failure handling.
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    "$NATIVE_DIR/DevicePermissionStore.m" "$NATIVE_DIR/tests/DevicePermissionStoreTests.m" \
    -framework Foundation -o "$TEST_BUILD_DIR/DevicePermissionStoreTests"
"$TEST_BUILD_DIR/DevicePermissionStoreTests"
