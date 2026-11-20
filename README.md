# ParcelScope CLI

Inspect the standalone Xcode Command Line Tools installation on macOS 14 or later. The optional uninstall command reviews the current boot volume and asks for two confirmations before removing matching files and receipts. The graphical ParcelScope app is optional.

## Install and inspect

Download the signed package and its SHA-256 file from [GitHub Releases](https://github.com/Snowpandora/ParcelScopeCLI/releases). In the download directory, use `shasum -a 256 -c <checksum-file>` and `pkgutil --check-signature <installer.pkg>` before opening the installer. Open a new login shell after installation.

```sh
parcelscope --version
parcelscope clt inspect
parcelscope clt inspect --json
```

Inspection runs as your own account and distinguishes unreadable data from verified absence. Software Update is a separate live observation. Use `/usr/sbin/softwareupdate --list` before and after removal to compare the same offer.

## Review and uninstall the standalone tools

```sh
sudo /Library/ParcelScopeCLI/bin/parcelscope clt uninstall
```

Review the target receipt IDs, paths, retained items and any index quarantine. Confirm with `REVIEWED`, then `REMOVE`, only if the displayed scope matches your intent. Partial completion requires a fresh inspection. Keep the recovery location the CLI prints for quarantined data. Removal can affect builds that use the standalone tools. Full Xcode has its own installation.

### Verify a quarantine record

Use `sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover` to list private recovery session IDs. Then run `sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover SESSION_UUID` to verify the preserved index bytes and the original path. A successful check can finish the outstanding recovery record after an interruption. Run a new inspection to assess the remaining receipts.

## Remove the CLI itself

To retire this package, remove the installed executable at `/Library/ParcelScopeCLI/bin/parcelscope` and its shell path file at `/private/etc/paths.d/me.rbbtsn0w.parcelscope.cli`. Remove the now-empty `bin` and `ParcelScopeCLI` directories with `rmdir`. Retire only the two CLI installer receipts using `sudo pkgutil --forget me.rbbtsn0w.parcelscope.cli` and `sudo pkgutil --forget me.rbbtsn0w.parcelscope.cli.path`. Quarantined files have their own recovery records and location.

## Build

Use Swift 6 on macOS. Run `swift test` and `swift build -c release`. The package exposes the read-only `ParcelScopeInspection` library and the `parcelscope` executable.

`Scripts/package.sh local 0.1.0 /path/to/output` builds an ad-hoc package for native testing. Release packaging uses `Scripts/package.sh release 0.1.0 /path/to/output` with `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER` and `NOTARY_PROFILE` from the signing environment. The release command builds both Mac architectures, verifies the signed binary, notarizes and staples the installer, assesses it with Gatekeeper and records the final SHA-256. Only release-mode installers are intended for distribution.

## Release workflow

For the GitHub-hosted release path, create the `cli-release` environment in the official repository and restrict its deployment branches to `main`. Use a required reviewer when a second maintainer is available. Keep the release workflow and signing scripts on the protected default branch.

| Environment secret | Value |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64 of a password-protected Developer ID Application PKCS#12 bundle |
| `DEVELOPER_ID_INSTALLER_P12_BASE64` | Base64 of a password-protected Developer ID Installer PKCS#12 bundle |
| `DEVELOPER_ID_P12_PASSWORD` | The password shared by the two bundles |
| `NOTARY_KEY_P8_BASE64` | Base64 of a team App Store Connect API key that has notarization access |

Set `DEVELOPER_ID_APPLICATION` and `DEVELOPER_ID_INSTALLER` to the full matching identity names. Set `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` to the API key ID and team issuer ID. These four settings are variables. Include the Apple intermediate certificate chain with the signing bundles. Use dedicated CI credentials where possible. Add secret values directly to the protected environment and keep the original key files out of the repository.

Run **Package CLI release** from the reviewed `main` commit with the version printed by `parcelscope --version`. The workflow tests that exact commit first. A hosted Mac builds the universal installer, signs both components and requires Apple's notarization status to be `Accepted`. It expands and verifies the final installer, then records the source commit and package digest in the run summary.

Start with the default `verify` mode for a full cloud acceptance run. It supports a version already released, since it only reports validation results. For a new release, use `draft` to add the verified package and checksum to a GitHub Release draft. This mode checks for an existing release or tag before signing. Review the draft before publishing. Inspect any incomplete draft before retrying an interrupted upload.

## License

MIT. See [LICENSE](LICENSE).
