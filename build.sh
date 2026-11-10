#!/bin/zsh
# Compila build/TunnelBar.app (universal arm64 + x86_64).
# Uso: ./build.sh [versión]      p. ej. ./build.sh 1.2.0
set -e
cd ${0:A:h}
VERSION=${1:-0.0.0-dev}
APP=build/TunnelBar.app

rm -rf build
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources build/obj
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos14 -parse-as-library \
    Sources/*.swift -o build/obj/TunnelBar-$arch
done
lipo -create build/obj/TunnelBar-* -output $APP/Contents/MacOS/TunnelBar

cp Info.plist $APP/Contents/
plutil -replace CFBundleShortVersionString -string ${VERSION#v} $APP/Contents/Info.plist
plutil -replace CFBundleVersion -string ${VERSION#v} $APP/Contents/Info.plist
cp Resources/tunnelbar-logo.png Resources/vpn-helper.sh install-helper.sh scripts/tunnelbar-cli $APP/Contents/Resources/

ICONSET=build/AppIcon.iconset
mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/tunnelbar-logo.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/tunnelbar-logo.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns
codesign --force --sign - $APP
echo "Compilada: $APP ($VERSION)"
