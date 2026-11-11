#!/bin/sh
set -eu
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
root=$PWD
GO=${GO:-go}
[ -f vendor/modules.txt ] && [ -f SOURCE-SHA256.txt ] || { echo 'Missing verified vendored source' >&2; exit 1; }
shasum -a 256 -c SOURCE-SHA256.txt > /dev/null
case "$($GO version)" in 'go version go1.26.10 '*) ;; *) echo 'Requires Go 1.26.10' >&2; exit 1;; esac
mkdir -p "$root/.build-core/tmp" "$root/.build-core/home" "$root/.build-core/cache" "$root/.build-core/modules"
export HOME="$root/.build-core/home" TMPDIR="$root/.build-core/tmp" GOCACHE="$root/.build-core/cache" GOMODCACHE="$root/.build-core/modules" GOPATH="$root/.build-core/gopath" GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOMAXPROCS=4
export CGO_ENABLED=0 GOOS=darwin GOARCH=arm64
"$GO" build -p 4 -mod=vendor -tags with_gvisor -trimpath -buildvcs=false -ldflags '-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=v1.19.33-harbor.1 -X github.com/metacubex/mihomo/constant.BuildTime=2026-11-08T00:00:00Z' -o "$root/.build-core/mihomo" .
"$GO" version -m "$root/.build-core/mihomo" > "$root/.build-core/build-info.txt"
if grep -E 'github.com/(easytier/easytier/easytier-go|rasky/go-lzo)' "$root/.build-core/build-info.txt"; then echo 'Excluded dependency detected' >&2; exit 1; fi
shasum -a 256 -c CORE-SHA256.txt
shasum -a 256 "$root/.build-core/mihomo"
echo 'Built .build-core/mihomo. This script does not run or install the proxy.'
