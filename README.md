# ParcelScope CLI

Inspect the standalone Xcode Command Line Tools installation on macOS 14 or later. The optional uninstall command reviews the current boot volume and asks for two confirmations before removing matching files and receipts. The graphical ParcelScope app is optional.

Version 0.1.0 is a development candidate. A notarized installer will be listed here after the standalone removal test and distribution checks pass.

## Install and inspect

When an installer is published, use the signed package and its SHA-256 file from [GitHub Releases](https://github.com/Snowpandora/ParcelScopeCLI/releases). In the download directory, use `shasum -a 256 -c <checksum-file>` and `pkgutil --check-signature <installer.pkg>` before opening the installer. Open a new login shell after installation.

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

## License

MIT. See [LICENSE](LICENSE).
