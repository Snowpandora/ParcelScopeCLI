#!/bin/bash
set -euo pipefail
export LC_ALL=C

[[ $# == 2 ]] || { printf 'Usage: %s VERSION RELEASE_DIRECTORY\n' "$0" >&2; exit 64; }
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 64
: "${DEVELOPER_ID_APPLICATION:?Missing Developer ID Application identity}"
: "${DEVELOPER_ID_INSTALLER:?Missing Developer ID Installer identity}"
cd "$2"
installer="ParcelScopeCLI-$version.pkg"
/usr/bin/shasum -a 256 -c "$installer.sha256"

signature=$(/usr/sbin/pkgutil --check-signature "$installer")
/usr/bin/grep -F "$DEVELOPER_ID_INSTALLER" <<< "$signature"
/usr/bin/xcrun stapler validate "$installer"
assessment=$(/usr/sbin/spctl --assess --type install --verbose=2 "$installer" 2>&1)
/usr/bin/grep -Fx 'source=Notarized Developer ID' <<< "$assessment"

scratch=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/parcelscope-verified-payload.XXXXXX")
trap '/bin/rm -rf "$scratch"' EXIT
/usr/sbin/pkgutil --expand-full "$installer" "$scratch/pkg"
binary="$scratch/pkg/CLI.pkg/Payload/bin/parcelscope"
case "$(/usr/bin/lipo -archs "$binary")" in
    'arm64 x86_64'|'x86_64 arm64') ;;
    *) printf 'The installer must contain a universal executable.\n' >&2; exit 1 ;;
esac
/usr/bin/codesign --verify --strict --all-architectures "$binary"
for arch in arm64 x86_64; do
    detail=$(/usr/bin/codesign --display --arch "$arch" --verbose=4 "$binary" 2>&1)
    /usr/bin/grep -Fx "Authority=$DEVELOPER_ID_APPLICATION" <<< "$detail"
    /usr/bin/grep -E '^CodeDirectory.*flags=.*\(.*runtime.*\)' <<< "$detail"
done
[[ $("$binary" --version) == "parcelscope $version" ]]
