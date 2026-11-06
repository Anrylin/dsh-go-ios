#!/usr/bin/env bash
# Node 24 的 iOS 库 (NodeMobile.xcframework)。只在 CI 里跑:要 unzip。
set -euo pipefail
version="24.20.0-0"
sha256="f97c5f368f5982fdc062b0f97d96d7696f94dbaf286fbd0d3c515b596088bca8"
root="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$root/app/ios/vendor"
zip="$dir/nodejs-mobile-$version.zip"
mkdir -p "$dir"
if [ ! -f "$zip" ]; then
  curl -fL --retry 3 -o "$zip.part" \
    "https://github.com/digidem/nodejs-mobile/releases/download/v$version/nodejs-mobile-ios-$version.zip"
  mv "$zip.part" "$zip"
fi
echo "$sha256  $zip" | shasum -a 256 -c -
rm -rf "$dir/NodeMobile.xcframework" "$dir/ios"
unzip -q "$zip" -d "$dir/ios"
mv "$dir/ios/NodeMobile.xcframework" "$dir/NodeMobile.xcframework"
rm -rf "$dir/ios"
echo "NodeMobile ready at $dir/NodeMobile.xcframework"
