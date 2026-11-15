#!/bin/zsh
set -eu
cd -- "${0:A:h}"
build="$PWD/build"
app="$build/屏幕模式.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$build/module-cache"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx12.0" \
    -module-cache-path "$build/module-cache" "$PWD"/Sources/*.swift \
    -o "$app/Contents/MacOS/ScreenModes"
/bin/cp "$PWD/Info.plist" "$app/Contents/Info.plist"
/bin/cp "$PWD/Assets/ScreenModes.icns" "$app/Contents/Resources/ScreenModes.icns"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict "$app"
print "已构建：$app"
