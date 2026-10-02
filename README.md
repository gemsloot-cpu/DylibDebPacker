# Dylib Deb Packer


### THIS FORK SIMPLY TRANSLATED THE ENTIRE UI TO ENGLISH

An on-device TrollStore utility for collecting jailbreak dylibs, extracting dylibs from deb packages, and building a custom rootless `iphoneos-arm64` deb.

## Features

- Import local `.dylib` and `.deb` files with the iOS document picker.
- Extract `.dylib` files from `data.tar` and `data.tar.gz` deb payloads.
- Add simple APT jailbreak repositories and read `Packages` / `Packages.gz`.
- Batch-import jailbreak repositories from clipboard text, including copied APT source lines.
- Download debs from a source, extract dylibs, and combine them with your own plugins.
- Generate a rootless deb under `/var/jb/Library/MobileSubstrate/DynamicLibraries`.
- Export the generated `.deb` from the iOS share sheet.
- Includes a real AppIcon for TrollStore home-screen installs.

## Build IPA

GitHub Actions builds an unsigned `.ipa` suitable for TrollStore installation.

1. Open the `Build IPA` workflow.
2. Run it manually.
3. Download the `DylibDebPacker-ipa` artifact.

## Notes

- Extraction supports uncompressed `data.tar` and gzip-compressed `data.tar.gz`.
- Repositories that only publish `Packages.xz`, `.bz2`, or `.zst` are not parsed yet.
- The app generates rootless packages by default: `/var/jb/Library/MobileSubstrate/DynamicLibraries`.
