#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

version_line="$(grep '^version:' pubspec.yaml | awk '{print $2}')"
version_name="${version_line%%+*}"

flutter build apk --release

mkdir -p build/releases
cp build/app/outputs/flutter-apk/app-release.apk \
  "build/releases/CarbTrack-${version_name}-release.apk"

echo "APK signé: build/releases/CarbTrack-${version_name}-release.apk"
