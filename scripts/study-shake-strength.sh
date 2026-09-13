#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

output=${1:-.build-cache/shake-strength-final-20260913}
if [ -e "$output" ]; then
    echo "output already exists: $output" >&2
    exit 1
fi
scratch=$(mktemp -d /private/tmp/smallwave-shake-study.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
mkdir -p "$(dirname "$output")"
mkdir "$output"
swiftc -O -module-cache-path "$scratch/modules" SmallWave/Core/LiquidSimulation.swift Studies/ShakeStrengthStudy.swift -o "$output/study"
"$output/study" "$output"
shasum -a 256 SmallWave/Core/LiquidSimulation.swift Studies/ShakeStrengthStudy.swift > "$output/source-sha256.txt"
