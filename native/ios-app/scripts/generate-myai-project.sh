#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
xcodegen generate --spec myai.yml
lock_dir=myai.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$lock_dir"
cp Package.resolved "$lock_dir/"
