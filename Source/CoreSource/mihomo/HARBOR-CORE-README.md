# Harbor patched Mihomo core

Base: MetaCubeX/mihomo v1.19.33. Upstream archive SHA256: e7c596b37ff27ec487d19b1920f73e0c97a78067ea35766530ee9659ade72711.
Source URL: https://github.com/MetaCubeX/mihomo/tree/v1.19.33
Core version: v1.19.33-harbor.1. Build date metadata: 2026-11-08T00:00:00Z.
License: GPL version 3 and applicable dependency licenses. Preserve LICENSE and all notices. Harbor's own GPL-3.0-or-later declaration does not change third-party grants.

## Changes

EasyTier is unavailable: its constructor always returns an explicit error. The EasyTier module and component implementation are removed, and NoEasyTier is true regardless of compiler tags. Its bundled WASM identified source commit 63519db2b5f2a6a1b9b7f20905f036dab54eb829, which the upstream repository could not resolve at audit time.
The rasky/go-lzo module is removed because its stated GPLv2 grant did not establish GPLv3 compatibility. OpenVPN LZO-compressed packets are explicitly rejected; uncompressed framing remains supported. Harbor's own supported protocol allowlist excludes both OpenVPN and EasyTier.

These changes are not a claim that all upstream tests passed. The release validates targeted LZO and EasyTier fail-closed tests and the host application's supported configurations separately.

## Offline rebuild

Use Go 1.26.10. Run GO=/path/to/go ./build-core.sh from this directory. The script verifies SOURCE-SHA256.txt, uses vendored modules without network access, limits parallelism to four, writes only beneath .build-core, and never starts or installs a proxy. The output is .build-core/mihomo. Compare its SHA256 with CORE-SHA256.txt. Files in this delivery target macOS arm64; unused Windows DLLs have been removed as listed in OMITTED-WINDOWS-BINARIES.txt.

Compiler flags: CGO_ENABLED=0 GOOS=darwin GOARCH=arm64; -tags with_gvisor; -trimpath; -buildvcs=false; -s -w -buildid=; fixed Version and BuildTime linker constants. Runtime feature output includes no_easytier because of the unconditional source constant, not an extra compiler build tag.

## Source and notices

The complete build inputs are this modified core source and vendor/. All 132 redistributed Go modules have license/notice paths in THIRD-PARTY-INVENTORY.json; THIRD-PARTY-NOTICES.txt reproduces those notices. Replacement dependencies are recorded in go.mod and vendor/modules.txt. GO-RUNTIME-LICENSE covers the Go runtime. No user profile, subscription, credential, proxy configuration, signing key, or compiler cache is included.

No executable WASM, DLL, native archive, or shared library is shipped in this macOS source artifact. Non-code embedded resources include ZeroTier's signed public root topology (default_planet.bin), protobuf edition defaults, public-suffix lookup data, and Tailscale version/public DNS metadata. Their source modules, parsers, notices, and exact bytes are supplied. The ZeroTier binary resource is data, not executable machine code; world.go documents its public Earth trust-anchor role.

Dependency acquisition used Go module checksum verification, with a public Go module mirror after the default endpoint failed. This choice did not modify system or app network settings. Rebuilding this source delivery does not download dependencies.
