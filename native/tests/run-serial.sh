#!/bin/sh
# PTY fixtures exercise real nonblocking serial I/O without accessing hardware.
set -eu
NATIVE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEST_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/safari-serial-tests.XXXXXX")
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT HUP INT TERM
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=13.0 \
    -DSERIAL_BACKEND_TESTING=1 -DSERIAL_WRITE_TIMEOUT_SECONDS=0.2 \
    "$NATIVE_DIR/SerialBackend.m" "$NATIVE_DIR/tests/SerialBackendTests.m" \
    -framework Foundation -framework IOKit -o "$TEST_BUILD_DIR/SerialBackendTests"
"$TEST_BUILD_DIR/SerialBackendTests"
