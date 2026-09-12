# BatSign

BatSign is an on-device IPA signer for iOS. It imports your own signing
certificate and provisioning profile, re-signs app packages directly on the
iPhone, and hands you back an installable file. No servers, no accounts, no
uploads: certificates and apps never leave the device.

The current build is compiled by GitHub Actions on every push to main and
published as a release when the full pipeline is green: compile, unit tests
on the iOS simulator, packaging, and an IPA structure check.

## What it does

Signing runs through the vendored zsign engine (MIT) with OpenSSL built for
arm64 iOS. You can override the display name, bundle identifier, version and
minimum OS, strip app extensions, watch apps, embedded profiles and device
limits, edit entitlements and Info.plist keys, replace the app icon, and
inject tweaks from .deb packages or raw dylibs.

Certificates are imported as a p12 plus provisioning profile and parsed with
public APIs. The app tracks expiry and warns you in advance. Signing jobs run
on a serial queue with a live engine log, survive app relaunches, and can be
re-run after interruption.

## Sources

The Discover tab accepts app sources in the AltStore JSON format. Add a URL
or import a local .json file, browse the catalog, and download and sign apps
in place. Downloads run on a background URL session, so they continue if you
leave the app, with progress shown on the Get button. When the package is
present, BatSign looks up the App Store catalog for ratings, artwork and
screenshots and shows them on the app page.

## Installing BatSign itself

Releases ship unsigned, because signing has to happen with a certificate you
control. Download BatSign.ipa from Releases and install it the same way you
install anything else: SideStore, Feather, AltStore, eSign, Sideloadly or
Xcode. Then open BatSign, import your p12 and profile, and sign.

BatSign signs packages; it does not install them to SpringBoard. Installing
the signed result needs an installer with device pairing, which is how every
signer in this category works.

## Honest limits

iOS suspends background apps aggressively. BatSign uses the sanctioned
mechanisms only: background URL sessions for downloads, BGTaskScheduler for
certificate checks, and an activity token so the device does not sleep
mid-sign. A signing job interrupted by the system is marked Interrupted and
re-runs in one tap. Injecting a tweak into a binary with no free load-command
space is impossible by design; BatSign signs such apps anyway and tells you
the tweak was skipped. Ad-hoc output is for testing and will not install on a
stock device.

## Building

macOS with Xcode 26 and Homebrew:

    brew install xcodegen
    ./scripts/build-openssl.sh
    ./scripts/build-zstd.sh
    swift scripts/make-icon.swift
    xcodegen generate
    xcodebuild -project BatSign.xcodeproj -scheme BatSign -configuration Release \
      -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
      CODE_SIGNING_ALLOWED=NO build
    ./scripts/make-ipa.sh

The same steps run in .github/workflows/build.yml on macos-26.

## Credits

zsign by zhlynn (MIT), OpenSSL (Apache-2.0), zstd (BSD), minizip (zlib
license). BatSign app code is MIT.

Made by @ihateios.
