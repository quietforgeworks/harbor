# Harbor 0.3.0 source snapshot

Harbor is a menu bar proxy client for macOS 26+ on Apple Silicon. It uses a native Swift/AppKit glass-style interface and the patched Mihomo v1.19.33-harbor.1 core, without a Dock icon.

## Interface and traffic

The main panel, settings, subscription providers, nodes, and rule editor share one menu bar panel. Back navigation preserves list positions and rule drafts. File imports use the system file picker.

The main panel tests the current node. The node page supports search, latency sorting, batch tests, and cancellation. Provider switching has a separate settings entry.

Upload and download each show the current rate and connection-session total. Rates use core byte-counter differences divided by the elapsed monotonic-clock interval, refreshing about every 2 seconds. Initial samples, failed reads, counter resets, and long sleep gaps display unavailable; no traffic displays 0 B/s. Statistics cover traffic handled by the core.

## Subscription providers

Paste an HTTPS subscription URL in settings and use + to add a provider. Importing the same URL updates the existing provider. Each provider retains its node selection, quota, update time, and automatic-update setting. URLs are stored in Keychain; local node configuration uses directory permissions 0700 and file permissions 0600.

Provider and node switches test the candidate first. Active connections reuse the current core, check the result, and restore the previous configuration if switching fails. Subscription updates preserve the active session; the new configuration applies on a later switch or reconnect.

Automatic updates follow the provider's `profile-update-interval`, defaulting to 24 hours. Failed downloads or validation retain the previous configuration and wait at least 15 minutes before an automatic retry. The app must remain running.

HTTPS DNS endpoints supplied for node-server domains are retained for node compatibility. Ordinary direct connections use system resolution. Harbor does not open a DNS listener, change macOS DNS, or apply a subscription's global rules, external controller, or TUN settings.

The 0.3.0 source snapshot adds proxy groups with up to five backup nodes, group latency tests, and failover. The downloadable release remains 0.2.0 build 8.

## Routing rules

Default rule mode routes OpenAI/ChatGPT, Anthropic/Claude, Google/Gemini, and their specified dependencies through the proxy. Apple services, local-network destinations, and other websites use direct connections. Global mode proxies external traffic while keeping local-network traffic direct.

The routing card opens the complete rule-mode editor. Supported rule types are `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD`, `IP-CIDR`, and `IP-CIDR6`; targets are `DIRECT`, `PROXY` (internally `SELECT`), and `REJECT`. Exactly one final `MATCH` rule is required.

Saving checks syntax and core compatibility, reloads active connections, and rolls back on failure. Restore Defaults removes the override. Imported legacy rule fragments are appended after the defaults. Rule-mode edits do not change global-mode behavior.

## Connection and recovery

Disconnect another proxy client before connecting Harbor. Harbor does not replace an active system proxy or TUN route. Initial HTTP/HTTPS system-proxy configuration may require macOS authorization.

Disconnecting or quitting restores system-proxy entries still owned by Harbor before stopping the core. A separate watchdog handles application or core exits, retains recovery records if restoration fails, and preserves settings changed by another application. Three consecutive failed node-health checks trigger an attempt to restore the previous network configuration.

## Current limitations

- Uses the system HTTP/HTTPS proxy, without TUN or a system-wide kill switch. Applications that ignore system proxies and UDP/QUIC traffic are not automatically covered.
- AI connectivity checks measure HTTPS responses, rather than account login, chat, uploads, or region access.
- The app is ad-hoc-signed and is not Apple-notarized.
- The patched core removes EasyTier and go-lzo dependencies. EasyTier requests and LZO-compressed data fail explicitly. EasyTier and OpenVPN are outside Harbor's supported node-protocol list.
- Real system-proxy takeover and forced-crash recovery, fresh installation, and independent macOS 26 testing remain incomplete.

## Build and validation

Use Xcode command-line tools supporting the macOS 26 SDK and Go 1.26.10. Run from this directory:

```sh
./build.sh
```

Yams, the patched Mihomo source, dependencies, and licenses are included. The build checks the source inventory and rebuilds the core from the bundled source without resolving remote dependencies. Build output and caches stay within the source directory.

Tests cover rule parsing, legacy configuration migration, provider switching, rollback, node testing, cancellation, traffic-rate calculation, and recovery transactions. Recorded interface checks cover forward/back transitions, closing and reopening, input, and window anchors.

Release 0.2.0 build 8 was tested on 2026-11-08 using Apple Silicon, macOS 27.2, and Xcode 27.2, with deployment target macOS 26.0. Release-specific results are in [VALIDATION.json](VALIDATION.json). The 0.3.0 source update passed 75 Swift unit tests and an app debug build; it has not completed release packaging, core rebuilding, or real-network and interface revalidation.

## Next steps

Validate proxy-group switching and failover on real connections, complete system-proxy recovery and fresh-install testing, and prepare a verified 0.3.0 release package.

## License and sources

Harbor uses GPL-3.0-or-later. See [LICENSE](LICENSE), [THIRD-PARTY.md](THIRD-PARTY.md), and [ROUTING-SOURCES.md](ROUTING-SOURCES.md).

Core changes, dependency licenses, checksums, and offline rebuilding instructions are in [CoreSource/mihomo/HARBOR-CORE-README.md](CoreSource/mihomo/HARBOR-CORE-README.md).
