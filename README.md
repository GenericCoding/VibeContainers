# VibeContainers

VibeContainers is an experimental iPhone and iPad host with an iOS-style shell and an embedded [LiveContainer](https://github.com/LiveContainer/LiveContainer) runtime for importing and running guest apps. It is not an emulator or a security boundary: guest apps run inside the host and may be able to access other guest data.

## Requirements

- macOS with Xcode 26 or newer and the iOS platform installed
- Git 2.13 or newer (for recursive submodules)
- An arm64 iPhone or iPad running iOS/iPadOS 17 or newer for installation and guest execution
- An Apple Developer account and a Development Team selected in Xcode for a signed device build

The project targets physical iOS devices. The unsigned command below checks compilation only; it does not produce an installable app. Simulator guest execution is not supported.

## Get the source

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/GenericCoding/VibeContainers.git
cd VibeContainers
```

If the repository is already cloned, initialize OpenSSL before opening Xcode:

```sh
git submodule update --init --recursive
./scripts/prepare_dependencies.sh
```

`prepare_dependencies.sh` verifies that OpenSSL is pinned to commit
`623c84da314e85363236507ca38a4bde65df21c3`. If a prior local build altered the
XCFramework's outer signature metadata, the script restores that metadata from
the pinned commit and verifies the vendor signature. It changes no LiveContainer
source files, and the committed OpenSSL submodule pin is unchanged.

## Build and run in Xcode

1. Open `iOSSim.xcodeproj` in Xcode and select the shared `iOSSim` scheme.
2. In **Signing & Capabilities**, choose your own Development Team for the app and embedded targets that Xcode reports as requiring signing.
3. Replace the example bundle identifiers with a namespace controlled by your account. Keep the app-extension identifiers unique and preserve their parent/child relationship. Keep the `ContainerWidgetRunner` identifier identical to the value used by `ContainerWidgetStore.swift`, `ContainerWidgetHost.m`, and `GuestSigner.m`.
4. Select a connected arm64 iPhone or iPad running iOS/iPadOS 17 or newer, then choose **Product > Run**.

Do not commit personal Team IDs, signing identities, provisioning profiles, certificate files, or certificate passwords. Xcode creates provisioning profiles for the identifiers and team you select.

## Build with `xcodebuild`

After configuring your Development Team and bundle namespace in Xcode, build the signed Debug configuration for a generic device:

```sh
xcodebuild \
  -project iOSSim.xcodeproj \
  -scheme iOSSim \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  build
```

To verify that Release sources compile without signing or provisioning:

```sh
xcodebuild \
  -project iOSSim.xcodeproj \
  -scheme iOSSim \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  DEVELOPMENT_TEAM= \
  build
```

Build products are written to Xcode's Derived Data directory by default.

## Upstream components

The complete LiveContainer source used by VibeContainers is included directly
in this repository. OpenSSL is the only large dependency kept as a submodule,
pinned to a known commit so the main repository remains compact. See
`LiveContainer-3.8.0/README.md` for runtime-specific behavior and limitations.

VibeContainers is proudly open source under the GNU Affero General Public
License v3.0.
