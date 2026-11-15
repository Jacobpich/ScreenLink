#!/bin/zsh
# Builds ScreenLink.app for Mac (Apple silicon + Intel) and zips it into Downloads/ScreenLink-Mac.zip.
set -e
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ScreenLinkMac
OUT=build/mac
APP=$OUT/ScreenLink.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/ScreenLink
sed "s/BUILD_NUMBER/$(date +%Y%m%d%H%M)/" Mac/Info.plist > $APP/Contents/Info.plist

# Icon from the iPhone app's 1024px icon.
ICONSET=$OUT/AppIcon.iconset
rm -rf $ICONSET && mkdir -p $ICONSET
SRC=ScreenLink/Assets.xcassets/AppIcon.appiconset/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s $SRC --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $SRC --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o $APP/Contents/Resources/AppIcon.icns

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -1)
codesign --force --timestamp=none --sign "${IDENTITY:--}" $APP
codesign --verify --strict $APP
mkdir -p Downloads
rm -f Downloads/ScreenLink-Mac.zip
ditto -c -k --keepParent $APP Downloads/ScreenLink-Mac.zip
ls -la Downloads/ScreenLink-Mac.zip
