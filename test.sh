#!/bin/zsh
set -eu
cd -- "${0:A:h}"
mkdir -p build/module-cache
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macosx12.0" \
    -module-cache-path "$PWD/build/module-cache" \
    Sources/DisplaySystem.swift Sources/Modes.swift Tests/main.swift -o build/test-modes
./build/test-modes
