# Harbor

Harbor is a menu bar proxy client for Apple Silicon Macs, with a native glass-style interface, subscription management, node testing, and routing-rule editing.

## Features

- Rule-based and global proxy modes, node selection, latency tests, and traffic statistics.
- Multiple subscription profiles, each with its own selected node, quota, and update settings.
- Connection checks before switching profiles or nodes, with rollback on failure.
- Full routing-rule editing, file import, and default-rule restoration.
- Subscription URLs stored in macOS Keychain and node configurations stored locally.
- The 0.3.0 source snapshot adds proxy groups with up to five backup nodes, group testing, and failover.

## Requirements and download

Requires **macOS 26 or later on Apple Silicon**.

The current [binary release](https://github.com/quietforgeworks/harbor/releases) is **Harbor 0.2.0, build 8**. It includes an application ZIP, corresponding source ZIP, SHA-256 checksums, and validation records.

The repository source is **0.3.0, build 8**, using the patched **Mihomo v1.19.33-harbor.1** core. The 0.3.0 source update passed 75 Swift unit tests and a debug build; a new binary release has not been packaged.

## Current limitations

- Harbor uses the system HTTP/HTTPS proxy. It does not include TUN or a system-wide kill switch, and applications that ignore the system proxy, including UDP/QUIC traffic, are not automatically covered.
- Existing system proxy settings must be disconnected before Harbor takes control.
- HTTPS connectivity tests check endpoint responses, not account login or service-specific access.
- Distribution uses ad-hoc signing and is not Apple-notarized.
- Live network switching, UI interaction, complete release packaging, and core rebuilding for the 0.3.0 snapshot still need validation. The existing `SHA256SUMS.txt` and `VALIDATION.json` describe the 0.2.0 release.

## Development directions

- Validate proxy-group switching and failover under real network conditions.
- Complete system-proxy takeover and crash-recovery tests.
- Test installation on a clean Mac and package the next binary release.

## Build and documentation

Use an Xcode toolchain supporting the macOS 26 SDK and Go 1.26.10, then run `Source/build.sh`. Yams, the patched Mihomo source, and required dependencies are included for offline rebuilding.

See the [source guide](Source/README.md) for usage, routing behavior, and build details.

## License

**GPL-3.0-or-later**. Third-party components retain their respective licenses. The core source package includes modification notes, dependency licenses, and reproducible-build instructions.
