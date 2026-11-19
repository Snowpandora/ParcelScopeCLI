#!/bin/bash
set -euo pipefail

usage() { printf 'Usage: %s local|release VERSION OUTPUT_DIRECTORY\n' "$0" >&2; exit 64; }
[[ $# == 3 ]] || usage
mode=$1 version=$2 output=$3
[[ $mode == local || $mode == release ]] || usage
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
if [[ $mode == release ]]; then
    : "${DEVELOPER_ID_APPLICATION:?Set the Developer ID Application identity}"
    : "${DEVELOPER_ID_INSTALLER:?Set the Developer ID Installer identity}"
    : "${NOTARY_PROFILE:?Set the notarytool keychain profile}"
    [[ $DEVELOPER_ID_APPLICATION == "Developer ID Application: "* && $DEVELOPER_ID_INSTALLER == "Developer ID Installer: "* ]] || usage
fi

project=$(cd "$(dirname "$0")/.." && pwd -P)
mkdir -p "$output"
output=$(cd "$output" && pwd -P)
stage=$(mktemp -d "${TMPDIR:-/tmp}/parcelscope-package.XXXXXX")
trap 'rm -rf "$stage"' EXIT
# Keep the compiler and Installer intermediates out of release artifacts.
payload="$stage/root"
bin="$payload/Library/ParcelScopeCLI/bin"
mkdir -p "$bin" "$payload/private/etc/paths.d"
printf '%s\n' '/Library/ParcelScopeCLI/bin' > "$payload/private/etc/paths.d/me.rbbtsn0w.parcelscope.cli"
build=(--package-path "$project" --scratch-path "$stage/build" -c release --arch arm64 --arch x86_64)
/usr/bin/xcrun swift build "${build[@]}" --product parcelscope
products=$(/usr/bin/xcrun swift build "${build[@]}" --show-bin-path)
/usr/bin/install -m 0755 "$products/parcelscope" "$bin/parcelscope"
binary="$bin/parcelscope"
[[ "$("$binary" --version)" == "parcelscope $version" ]] || { echo 'Installer version differs from the executable.' >&2; exit 1; }
architectures=$(/usr/bin/lipo -archs "$binary")
case "$architectures" in
    "arm64 x86_64"|"x86_64 arm64") ;;
    *) printf 'Expected arm64 and x86_64, found %s\n' "$architectures" >&2; exit 1 ;;
esac
if [[ $mode == release ]]; then
    /usr/bin/codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$binary"
else
    /usr/bin/codesign --force --options runtime --sign - "$binary"
fi
/usr/bin/codesign --verify --strict "$binary"
/usr/bin/codesign --display --verbose=4 "$binary"
name="ParcelScopeCLI-$version"
if [[ $mode == local ]]; then name="$name-local"; fi
pkg="$stage/$name.pkg"
# Building a component for each location avoids changing the ownership of /etc or /Library.
/usr/bin/pkgbuild --root "$payload/Library/ParcelScopeCLI" --ownership recommended --install-location /Library/ParcelScopeCLI --identifier me.rbbtsn0w.parcelscope.cli --version "$version" "$stage/CLI.pkg"
/usr/bin/pkgbuild --root "$payload/private/etc/paths.d" --ownership recommended --install-location /private/etc/paths.d --identifier me.rbbtsn0w.parcelscope.cli.path --version "$version" "$stage/Path.pkg"
/usr/bin/productbuild --synthesize --package "$stage/CLI.pkg" --package "$stage/Path.pkg" "$stage/Distribution.xml"
args=(--distribution "$stage/Distribution.xml" --package-path "$stage")
if [[ $mode == release ]]; then args+=(--sign "$DEVELOPER_ID_INSTALLER" --timestamp); fi
/usr/bin/productbuild "${args[@]}" "$pkg"
if [[ $mode == release ]]; then
    /usr/sbin/pkgutil --check-signature "$pkg"
    /usr/bin/xcrun notarytool submit "$pkg" --keychain-profile "$NOTARY_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$pkg"
    /usr/bin/xcrun stapler validate "$pkg"
    /usr/sbin/spctl --assess --type install --verbose=2 "$pkg"
fi
/usr/bin/install -m 0644 "$pkg" "$output/$name.pkg"
(cd "$output" && /usr/bin/shasum -a 256 "$name.pkg" > "$name.pkg.sha256")
