# Core validation, 2026-11-08

- Go 1.26.10 Darwin arm64 compilation: passed.
- Binary build metadata: neither github.com/easytier/easytier/easytier-go nor github.com/rasky/go-lzo is present.
- LZO isolated regression tests: passed.
- Selected transport/openvpn package tests: passed (0.397 s).
- EasyTier fail-closed constructor test in adapter/outbound: passed (0.454 s).
- Offline rebuild from the delivered pruned vendored source: identical SHA256 to first build.
- Binary SHA256: 864c4877c61372157bfb838d50f600dcf290c87fbd67d236952908c7a540c82d.
- Version: Mihomo Meta v1.19.33-harbor.1 darwin arm64 with go1.26.10 2026-11-08T00:00:00Z.
- Runtime feature tags: no_easytier, with_gvisor. Compiler build tag: with_gvisor.
- Mach-O minimum macOS version: 12.0.
- No full upstream network/TUN test suite was run. Application integration tests are a separate validation step.
- No proxy process was launched during core verification; the version-only command exits before runtime setup.
