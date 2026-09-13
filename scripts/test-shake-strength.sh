#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d /private/tmp/smallwave-shake-test.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
swiftc -O -module-cache-path "$scratch/modules" SmallWave/Core/LiquidSimulation.swift Tests/ShakeStrengthCheck.swift -o "$scratch/check"
"$scratch/check"
