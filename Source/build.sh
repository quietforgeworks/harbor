#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
base="$PWD"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Requires an Apple Silicon Mac' >&2; exit 1; }
cache="$base/.build-harbor"
mkdir -p "$cache/tmp" "$cache/home" "$cache/modules" "$cache/packages" "$cache/staging.nosync"
export TMPDIR="$cache/tmp/" HOME="$cache/home" CFFIXED_USER_HOME="$cache/home"
export CLANG_MODULE_CACHE_PATH="$cache/modules" SWIFTPM_MODULECACHE_OVERRIDE="$cache/modules"
core="$base/CoreSource/mihomo"
[[ -x "$core/build-core.sh" ]] || { echo 'Missing corresponding patched core source' >&2; exit 1; }
"$core/build-core.sh"
swift test -j 4 --scratch-path "$cache/build" --cache-path "$cache/packages" --disable-sandbox
swift build -j 4 -c release --scratch-path "$cache/build" --cache-path "$cache/packages" --disable-sandbox
stage=$(mktemp -d "$cache/staging.nosync/package.XXXXXX")
app="$stage/Harbor.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$cache/build/release/Harbor" "$app/Contents/MacOS/Harbor"
cp "$core/.build-core/mihomo" "$app/Contents/Resources/mihomo"
cp Info.plist "$app/Contents/Info.plist"
cp Assets/Harbor.icns "$app/Contents/Resources/Harbor.icns"
cp LICENSE "$app/Contents/Resources/Harbor-LICENSE"
cp "$core/LICENSE" "$app/Contents/Resources/Mihomo-LICENSE"
cp Vendor/Yams/LICENSE "$app/Contents/Resources/Yams-LICENSE"
cp Vendor/Yams/libyaml-LICENSE "$app/Contents/Resources/libyaml-LICENSE"
for name in THIRD-PARTY-NOTICES.txt THIRD-PARTY-INVENTORY.json GO-RUNTIME-LICENSE HARBOR-CORE-README.md; do cp "$core/$name" "$app/Contents/Resources/$name"; done
xattr -cr "$app"
codesign --force --sign - "$app/Contents/Resources/mihomo"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$base/dist"
(cd "$stage" && COPYFILE_DISABLE=1 /usr/bin/zip -qry "$base/dist/Harbor-0.3.0-macOS-arm64.zip" Harbor.app)
echo "Built: $base/dist/Harbor-0.3.0-macOS-arm64.zip"
echo 'The app was not installed or started, and system proxy settings were not changed.'
