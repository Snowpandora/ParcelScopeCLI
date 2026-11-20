#!/bin/bash
set -euo pipefail
umask 077

[[ $# == 2 ]] || { printf 'Usage: %s VERSION OUTPUT_DIRECTORY\n' "$0" >&2; exit 64; }
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_EVENT_NAME:-} == workflow_dispatch && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
    printf 'Run this script from the manual GitHub-hosted release job.\n' >&2
    exit 64
}

: "${RUNNER_TEMP:?Missing runner temporary directory}"
: "${DEVELOPER_ID_APPLICATION:?Missing Developer ID Application identity}"
: "${DEVELOPER_ID_INSTALLER:?Missing Developer ID Installer identity}"
: "${DEVELOPER_ID_APPLICATION_P12_BASE64:?Missing Application signing bundle}"
: "${DEVELOPER_ID_INSTALLER_P12_BASE64:?Missing Installer signing bundle}"
: "${DEVELOPER_ID_P12_PASSWORD:?Missing signing bundle password}"
: "${NOTARY_KEY_P8_BASE64:?Missing notarization key}"
: "${NOTARY_KEY_ID:?Missing notarization key ID}"
: "${NOTARY_ISSUER_ID:?Missing notarization issuer ID}"

project=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(/usr/bin/mktemp -d "$RUNNER_TEMP/parcelscope-signing.XXXXXX")
keychain="$scratch/release.keychain-db"
cleanup() {
    /usr/bin/security delete-keychain "$keychain" 2>/dev/null || true
    /bin/rm -rf "$scratch"
}
trap cleanup EXIT

printf '%s' "$DEVELOPER_ID_APPLICATION_P12_BASE64" | /usr/bin/base64 -D -o "$scratch/application.p12"
printf '%s' "$DEVELOPER_ID_INSTALLER_P12_BASE64" | /usr/bin/base64 -D -o "$scratch/installer.p12"
printf '%s' "$NOTARY_KEY_P8_BASE64" | /usr/bin/base64 -D -o "$scratch/notary.p8"
unset DEVELOPER_ID_APPLICATION_P12_BASE64 DEVELOPER_ID_INSTALLER_P12_BASE64 NOTARY_KEY_P8_BASE64

# Add the temporary keychain to the hosted runner's search list so codesign can embed its intermediate certificates.
keychain_password=$(/usr/bin/openssl rand -hex 32)
/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 3600 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security import "$scratch/application.p12" -f pkcs12 -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
/usr/bin/security import "$scratch/installer.p12" -f pkcs12 -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/productbuild
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain" >/dev/null
/usr/bin/security list-keychains -d user -s "$keychain"
unset keychain_password DEVELOPER_ID_P12_PASSWORD

export PARCELSCOPE_SIGNING_KEYCHAIN="$keychain"
export NOTARY_PROFILE=ParcelScopeCLI-Release
/usr/bin/xcrun notarytool store-credentials "$NOTARY_PROFILE" \
    --keychain "$keychain" --key "$scratch/notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --validate
/bin/rm -f "$scratch/application.p12" "$scratch/installer.p12" "$scratch/notary.p8"
"$project/Scripts/package.sh" release "$1" "$2"
