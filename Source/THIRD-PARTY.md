# Sources and licenses

Harbor 0.2.0 build 8 is provided under GPL-3.0-or-later; see LICENSE. Third-party grants remain unchanged.

- Patched Mihomo v1.19.33-harbor.1, based on MetaCubeX/mihomo v1.19.33, GPL version 3 and applicable dependency licenses. Corresponding modified source, all required vendored Go dependencies, patch, provenance, notices, source manifest and offline build script are included in CoreSource/mihomo. EasyTier and rasky/go-lzo are excluded. See HARBOR-CORE-README.md and THIRD-PARTY-INVENTORY.json there. The core is built with Go 1.26.10; GO-RUNTIME-LICENSE is included.
- Yams 6.2.2, jpsim, MIT: https://github.com/jpsim/Yams/tree/6.2.2 . Complete source and LICENSE are in Vendor/Yams.
- libyaml 0.2.5, Kirill Simonov and contributors, MIT: source is included within Vendor/Yams and its copyright/license text is reproduced in Vendor/Yams/libyaml-LICENSE.

The app bundle reproduces the above notices in Contents/Resources. The complete matching source accompanies the binary release. The distributed core's executable signature changes when the app is locally ad-hoc signed; release ZIP hashes are recorded separately from the reproducible unsigned core hash.

Requirements: Apple Silicon, macOS 26 or later. The app is ad-hoc signed, without Developer ID signing or Apple notarization. No signing keys, subscriptions, API credentials or user node configuration are included.
