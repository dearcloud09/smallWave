#!/bin/sh
# Synthetic 2 Hz video using the app renderer and an isolated physics fixture.
set -eu
cd "$(dirname "$0")/.."
[ "$#" -le 1 ] || exit 2
gain="${1:-5.8}"
mkdir -p .build-cache/swift-modules .build-cache/shake-response
run=$(mktemp -d .build-cache/shake-response/movie-XXXXXX)
swiftc -O -module-cache-path .build-cache/swift-modules \
  Studies/Fixtures/ShakeSimulation.swift SmallWave/Core/OceanStyle.swift \
  SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift \
  SmallWave/Rendering/LiquidVolumeRenderer.swift Studies/FastShakeMovie.swift \
  -o "$run/shake-movie"
"$run/shake-movie" "$gain" "$run"
