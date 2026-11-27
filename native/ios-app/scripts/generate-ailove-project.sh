#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --spec ailove.yml
lock_dir=ailove.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$lock_dir"
cp Package.resolved "$lock_dir/"
