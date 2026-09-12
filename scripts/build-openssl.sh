#!/bin/bash
# Builds libcrypto (OpenSSL) static libraries for iOS — required by the
# vendored zsign engine.
#
# Layout (headers are platform-independent, libraries are not):
#   Vendor/openssl/include/openssl/*.h        shared by all platforms
#   Vendor/openssl/iphoneos/libcrypto.a
#   Vendor/openssl/iphonesimulator/libcrypto.a
#
# Xcode selects the library slice via $(PLATFORM_NAME).
# Usage: build-openssl.sh [iphoneos|iphonesimulator|all]
#
# Targets come from OpenSSL's own Configurations/15-ios.conf:
#   device      -> ios64-xcrun              (xcrun -sdk iphoneos cc)
#   simulator   -> iossimulator-arm64-xcrun (xcrun -sdk iphonesimulator cc)
set -euo pipefail

OPENSSL_VERSION="${OPENSSL_VERSION:-3.5.2}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor/openssl"

build_one() {
  local target="$1" outdir="$2"
  local libdir="$VENDOR/$outdir"
  if [ -f "$libdir/libcrypto.a" ]; then
    echo "[openssl] $outdir already built — skipping"
    return 0
  fi
  echo "[openssl] building OpenSSL ${OPENSSL_VERSION} for $target"

  local work
  work="$(mktemp -d /tmp/batsign-openssl.XXXXXX)"
  trap 'rm -rf "$work"' RETURN

  curl -sSL --retry 3 --retry-delay 5 -o "$work/openssl.tar.gz" \
    "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
  tar -xzf "$work/openssl.tar.gz" -C "$work"
  cd "$work/openssl-${OPENSSL_VERSION}"

  local noasm_flag=""
  if [ "${OPENSSL_NO_ASM:-0}" = "1" ]; then
    noasm_flag="no-asm"
  fi

  # `-xcrun` targets locate the compiler themselves; no CROSS_TOP needed.
  #
  # no-module is required, not cosmetic: Apple Keychain exports .p12 files with
  # pbeWithSHA1And40BitRC2-CBC, whose RC2 implementation lives in OpenSSL's
  # legacy provider. By default that provider is built as a *loadable module*,
  # which cannot exist in a static no-shared iOS link — zsign's
  # OSSL_PROVIDER_load(NULL, "legacy") therefore fails and every real user
  # certificate dies with "Can't load p12 or private key file". no-module
  # compiles the legacy provider into libcrypto as a builtin (STATIC_LEGACY).
  ./Configure "$target" $noasm_flag \
    no-shared no-module no-tests no-docs no-ui-console no-external-tests

  make -j "$(sysctl -n hw.ncpu)" build_libs

  mkdir -p "$libdir"
  cp libcrypto.a "$libdir/libcrypto.a"

  # Headers are identical across platforms; publish once.
  if [ ! -d "$VENDOR/include/openssl" ]; then
    mkdir -p "$VENDOR/include"
    cp -R include/openssl "$VENDOR/include/openssl"
  fi

  echo "[openssl] done → $libdir/libcrypto.a ($(du -h "$libdir/libcrypto.a" | cut -f1))"
}

case "${1:-all}" in
  iphoneos)          build_one ios64-xcrun iphoneos ;;
  iphonesimulator)   build_one iossimulator-arm64-xcrun iphonesimulator ;;
  all)               build_one ios64-xcrun iphoneos
                     build_one iossimulator-arm64-xcrun iphonesimulator ;;
  *) echo "unknown platform: $1 (expected iphoneos|iphonesimulator|all)" >&2; exit 1 ;;
esac
