#!/bin/sh
# Offline fixed-input experiment; does not modify or install the app.
set -eu
cd "$(dirname "$0")/.."
[ "$#" -le 4 ] || exit 2
gain="${1:-5.8}"
frequency="${2:-2}"
amplitude="${3:-1}"
input_cap="${4:-3}"
mkdir -p .build-cache/swift-modules .build-cache/shake-response
run=$(mktemp -d .build-cache/shake-response/run-XXXXXX)
swiftc -O -module-cache-path .build-cache/swift-modules \
  Studies/Fixtures/ShakeSimulation.swift Studies/ShakeResponse.swift \
  -o "$run/shake-response"
"$run/shake-response" "$gain" translation "$run" "$frequency" "$amplitude" "$input_cap" > "$run/run.log"
cat "$run/run.log"
printf 'output=%s\n' "$run"
