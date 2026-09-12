#!/bin/sh
# Compile app + embedded widget. Signing uses the team already selected in Xcode.
set -eu

cd "$(dirname "$0")/.."
platform="${1:-simulator}"
usage() { echo 'Usage: sh scripts/build-ios.sh [simulator|device] [--signed]' >&2; exit 2; }
[ "$#" -le 2 ] || usage
case "$platform" in
  simulator) sdk=iphonesimulator; destination='generic/platform=iOS Simulator' ;;
  device) sdk=iphoneos; destination='generic/platform=iOS' ;;
  *) usage ;;
esac
signing=NO
suffix=""
case "${2:-}" in
  '') ;;
  --signed) [ "$platform" = device ] || usage; signing=YES; suffix=-signed ;;
  *) usage ;;
esac
# Keep disposable bundles outside the synced Documents folder. FinderInfo on a
# built bundle caused codesign to reject it; source and security attributes stay intact.
build_root="${SMALLWAVE_DERIVED_DATA_ROOT:-/private/tmp/smallwave-xcode}"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  export DEVELOPER_DIR
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Xcode setup is not ready. Finish its first launch and install the iOS components.' >&2
  exit 1
fi

exec xcodebuild -project SmallWave.xcodeproj -scheme SmallWave \
  -configuration Debug -sdk "$sdk" -destination "$destination" \
  -derivedDataPath "$build_root/DerivedData-$platform$suffix" \
  CODE_SIGNING_ALLOWED="$signing" build
