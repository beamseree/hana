#!/bin/zsh
set -eu
cd "${0:A:h}"
app="$PWD/build/Window Focus Prototype.app"
mkdir -p "$app/Contents/MacOS"
xcrun swiftc -swift-version 6 -target arm64-apple-macosx26.0 -framework AppKit -framework Carbon -framework ApplicationServices Sources.swift -o "$app/Contents/MacOS/WindowFocusPrototype"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
print -r -- "$app"
