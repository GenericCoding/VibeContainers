#!/bin/sh

set -eu

script_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
team_id=${DEVELOPMENT_TEAM:-}
bundle_id=""
configuration=Debug
unsigned=0
developer_dir=${DEVELOPER_DIR:-}
device_id=""
certificate_path=""
output_path=""
derived_data_path=${VIBECONTAINERS_DERIVED_DATA_PATH:-${TMPDIR:-/private/tmp}/VibeContainersDerivedData}
ipa_temp=""

usage() {
    cat <<'EOF'
Build a signed or unsigned VibeContainers IPA.

Usage:
  scripts/build_ipa.sh --team-id TEAM_ID [options]
  scripts/build_ipa.sh --unsigned [options]

Required:
  --team-id TEAM_ID         Apple Developer Team ID for signed builds.

Options:
  --bundle-id BUNDLE_ID     Main bundle ID. Default: com.team<team-id>.vibecontainers
  --certificate FILE        Bundle a local .p12 or .pfx identity for on-device import.
  --configuration NAME      Debug or Release. Default: Debug
  --developer-dir PATH      Xcode Developer directory or Xcode.app path.
  --device UDID             Build for one device and allow device registration.
  --derived-data PATH       Derived Data directory.
  --output FILE             IPA path. Default: build/VibeContainers-<configuration>.ipa
  --unsigned                Disable code signing. The IPA must be signed before installation.
  -h, --help                Show this help.

DEVELOPMENT_TEAM can supply the Team ID for a signed build.
The certificate password is never passed to this script or stored in the IPA.
Enter it in VibeContainers under Settings > JIT & Containers.
EOF
}

fail() {
    echo "error: $*" >&2
    exit 1
}

need_value() {
    [ "$#" -ge 2 ] || fail "$1 requires a value"
}

cleanup() {
    if [ -n "$ipa_temp" ] && [ -e "$ipa_temp" ]; then
        if command -v trash >/dev/null 2>&1; then
            trash "$ipa_temp" >/dev/null 2>&1 || true
        else
            echo "warning: temporary archive remains at $ipa_temp" >&2
        fi
    fi
}

trap cleanup EXIT INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --team-id)
            need_value "$@"
            team_id=$2
            shift 2
            ;;
        --bundle-id)
            need_value "$@"
            bundle_id=$2
            shift 2
            ;;
        --certificate)
            need_value "$@"
            certificate_path=$2
            shift 2
            ;;
        --configuration)
            need_value "$@"
            configuration=$2
            shift 2
            ;;
        --developer-dir)
            need_value "$@"
            developer_dir=$2
            shift 2
            ;;
        --device)
            need_value "$@"
            device_id=$2
            shift 2
            ;;
        --derived-data)
            need_value "$@"
            derived_data_path=$2
            shift 2
            ;;
        --output)
            need_value "$@"
            output_path=$2
            shift 2
            ;;
        --unsigned)
            unsigned=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

if [ "$unsigned" -eq 0 ]; then
    [ -n "$team_id" ] || fail "--team-id or DEVELOPMENT_TEAM is required for a signed build"
    [ "${#team_id}" -eq 10 ] || fail "Team ID must contain 10 characters"
    case "$team_id" in
        *[!A-Za-z0-9]*) fail "Team ID can contain only letters and numbers" ;;
    esac
else
    [ -z "$certificate_path" ] || fail "--certificate cannot be used with --unsigned"
    [ -z "$device_id" ] || fail "--device cannot be used with --unsigned"
fi

case "$configuration" in
    Debug|Release) ;;
    *) fail "configuration must be Debug or Release" ;;
esac

if [ -z "$bundle_id" ]; then
    if [ "$unsigned" -eq 1 ]; then
        bundle_id="com.genericcoding.vibecontainers"
    else
        team_slug=$(printf '%s' "$team_id" | tr '[:upper:]' '[:lower:]')
        bundle_id="com.team${team_slug}.vibecontainers"
    fi
fi
case "$bundle_id" in
    ""|.*|*.|*..*|*[!A-Za-z0-9.-]*) fail "invalid bundle identifier: $bundle_id" ;;
esac

if [ -n "$certificate_path" ]; then
    [ -f "$certificate_path" ] || fail "certificate file not found: $certificate_path"
    certificate_name=$(basename -- "$certificate_path")
    case $(printf '%s' "$certificate_name" | tr '[:upper:]' '[:lower:]') in
        *.p12|*.pfx) ;;
        *) fail "certificate must have a .p12 or .pfx extension" ;;
    esac
    certificate_parent=$(CDPATH= cd -- "$(dirname -- "$certificate_path")" && pwd)
    certificate_path="$certificate_parent/$certificate_name"
    echo "warning: the IPA will contain an extractable private signing identity" >&2
    echo "warning: do not publish or share the resulting IPA" >&2
fi

if [ -z "$developer_dir" ]; then
    developer_dir=$(xcode-select -p)
fi
case "$developer_dir" in
    *.app) developer_dir="$developer_dir/Contents/Developer" ;;
esac
[ -x "$developer_dir/usr/bin/xcodebuild" ] || fail "invalid Xcode Developer directory: $developer_dir"
export DEVELOPER_DIR=$developer_dir

case "$derived_data_path" in
    /*) ;;
    *) derived_data_path="$PWD/$derived_data_path" ;;
esac
mkdir -p "$derived_data_path"
derived_data_path=$(CDPATH= cd -- "$derived_data_path" && pwd)

if [ -z "$output_path" ]; then
    output_suffix=""
    if [ "$unsigned" -eq 1 ]; then
        output_suffix="-unsigned"
    fi
    output_path="$script_root/build/VibeContainers-${configuration}${output_suffix}.ipa"
elif [ "${output_path#/}" = "$output_path" ]; then
    output_path="$PWD/$output_path"
fi
output_parent=$(dirname -- "$output_path")
mkdir -p "$output_parent"
output_parent=$(CDPATH= cd -- "$output_parent" && pwd)
output_path="$output_parent/$(basename -- "$output_path")"
case $(printf '%s' "$output_path" | tr '[:upper:]' '[:lower:]') in
    *.ipa) ;;
    *) fail "output file must have an .ipa extension" ;;
esac

destination="generic/platform=iOS"
if [ -n "$device_id" ]; then
    destination="platform=iOS,id=$device_id"
fi

git -C "$script_root" submodule update --init --recursive
"$script_root/scripts/prepare_dependencies.sh"

set -- /usr/bin/xcrun xcodebuild -quiet \
    -project "$script_root/iOSSim.xcodeproj" \
    -scheme iOSSim \
    -sdk iphoneos \
    -configuration "$configuration" \
    -destination "$destination" \
    -derivedDataPath "$derived_data_path"
if [ "$unsigned" -eq 1 ]; then
    set -- "$@" \
        DEVELOPMENT_TEAM= \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY= \
        "VIBECONTAINERS_BUNDLE_IDENTIFIER=$bundle_id"
else
    set -- "$@" -allowProvisioningUpdates
    if [ -n "$device_id" ]; then
        set -- "$@" -allowProvisioningDeviceRegistration
    fi
    set -- "$@" \
        "DEVELOPMENT_TEAM=$team_id" \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGNING_REQUIRED=YES \
        "CODE_SIGN_IDENTITY=Apple Development" \
        "VIBECONTAINERS_BUNDLE_IDENTIFIER=$bundle_id"
fi
if [ -n "$certificate_path" ]; then
    set -- "$@" "VIBECONTAINERS_CERTIFICATE_PATH=$certificate_path"
fi
set -- "$@" clean build
"$@"

app_path="$derived_data_path/Build/Products/${configuration}-iphoneos/iOSSim.app"
[ -d "$app_path" ] || fail "built app not found: $app_path"

actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")
[ "$actual_bundle_id" = "$bundle_id" ] || fail "built bundle ID is $actual_bundle_id, expected $bundle_id"

if [ -n "$certificate_path" ]; then
    bundled_certificate="$app_path/VibeContainersSigner.p12"
    [ -f "$bundled_certificate" ] || fail "the certificate was not copied into the app"
    cmp -s "$certificate_path" "$bundled_certificate" || fail "the bundled certificate does not match the input"
else
    [ ! -e "$app_path/VibeContainersSigner.p12" ] || fail "the app contains a stale bundled certificate"
fi

if [ "$unsigned" -eq 1 ]; then
    find "$app_path" -depth -type d \( \
        -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \
    \) -exec sh -c '
        for code_path do
            if /usr/bin/codesign --display "$code_path" >/dev/null 2>&1; then
                /usr/bin/codesign --remove-signature "$code_path"
            fi
        done
    ' sh {} +
    find "$app_path" -type f -perm -111 -exec sh -c '
        for code_path do
            if /usr/bin/codesign --display "$code_path" >/dev/null 2>&1; then
                /usr/bin/codesign --remove-signature "$code_path"
            fi
        done
    ' sh {} +

    profile_path=$(find "$app_path" -name embedded.mobileprovision -print -quit)
    [ -z "$profile_path" ] || fail "unsigned app contains an embedded provisioning profile: $profile_path"
    identity_path=$(find "$app_path" -type f \( -iname '*.p12' -o -iname '*.pfx' \) -print -quit)
    [ -z "$identity_path" ] || fail "unsigned app contains a PKCS#12 identity: $identity_path"
    signed_code=$(find "$app_path" -type f -perm -111 -exec sh -c '
        for code_path do
            if /usr/bin/codesign --display "$code_path" >/dev/null 2>&1; then
                printf "%s\n" "$code_path"
                break
            fi
        done
    ' sh {} +)
    [ -z "$signed_code" ] || fail "unsigned app contains signed code: $signed_code"
else
    codesign --verify --deep --strict --verbose=2 "$app_path"
fi

temp_base=${TMPDIR:-/private/tmp}
temp_base=${temp_base%/}
ipa_temp=$(mktemp "$temp_base/VibeContainers.XXXXXX")
product_directory=$(dirname -- "$app_path")
(
    cd "$product_directory"
    if [ "$unsigned" -eq 1 ]; then
        /usr/bin/bsdtar --format zip --no-xattrs \
            --exclude '*/_CodeSignature' \
            --exclude '*/_CodeSignature/*' \
            -cf "$ipa_temp" \
            -s '|^iOSSim\.app|Payload/iOSSim.app|' iOSSim.app
    else
        /usr/bin/bsdtar --format zip --no-xattrs -cf "$ipa_temp" \
            -s '|^iOSSim\.app|Payload/iOSSim.app|' iOSSim.app
    fi
)
/usr/bin/unzip -tq "$ipa_temp"
if [ "$unsigned" -eq 1 ] && /usr/bin/unzip -Z1 "$ipa_temp" | \
    grep -Eqi '(^|/)(_CodeSignature(/|$)|embedded\.mobileprovision$|[^/]+\.(p12|pfx)$)'; then
    fail "unsigned IPA contains signing material"
fi
/bin/mv -f "$ipa_temp" "$output_path"
ipa_temp=""
if [ -n "$certificate_path" ]; then
    chmod 0600 "$output_path"
else
    chmod 0644 "$output_path"
fi

echo "IPA: $output_path"
echo "Bundle ID: $bundle_id"
echo "Configuration: $configuration"
if [ "$unsigned" -eq 1 ]; then
    echo "Signing: unsigned; sign the IPA before installation"
fi
if [ -n "$certificate_path" ]; then
    echo "Bundled certificate: VibeContainersSigner.p12"
fi
shasum -a 256 "$output_path"
