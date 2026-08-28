#!/bin/sh

set -eu

script_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
openssl_root="$script_root/LiveContainer-3.8.0/OpenSSL"
openssl_xcframework="$openssl_root/Frameworks/OpenSSL.xcframework"
expected_openssl_commit="623c84da314e85363236507ca38a4bde65df21c3"

if ! git -C "$openssl_root" rev-parse --git-dir >/dev/null 2>&1; then
    echo "OpenSSL is not initialized. Run: git submodule update --init --recursive" >&2
    exit 1
fi

actual_openssl_commit=$(git -C "$openssl_root" rev-parse HEAD)
if [ "$actual_openssl_commit" != "$expected_openssl_commit" ]; then
    echo "Unexpected OpenSSL commit: $actual_openssl_commit" >&2
    echo "Expected: $expected_openssl_commit" >&2
    exit 1
fi

if [ ! -d "$openssl_xcframework" ]; then
    echo "Missing OpenSSL XCFramework: $openssl_xcframework" >&2
    exit 1
fi

if ! codesign --verify "$openssl_xcframework" >/dev/null 2>&1; then
    git -C "$openssl_root" restore \
        --source="$expected_openssl_commit" \
        --worktree \
        -- Frameworks/OpenSSL.xcframework/_CodeSignature
fi

if ! codesign --verify "$openssl_xcframework" >/dev/null 2>&1; then
    echo "OpenSSL XCFramework signature verification failed." >&2
    echo "Reset the OpenSSL submodule and retry dependency preparation." >&2
    exit 1
fi

echo "OpenSSL is ready at $expected_openssl_commit"
