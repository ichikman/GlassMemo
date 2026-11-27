#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .build/ModuleCache build/GlassMemo.app/Contents/MacOS
cp Info.plist build/GlassMemo.app/Contents/Info.plist
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
swiftc main.swift -o build/GlassMemo.app/Contents/MacOS/GlassMemo -framework Cocoa -framework Carbon -target arm64-apple-macosx13.0
codesign --force --sign - build/GlassMemo.app
