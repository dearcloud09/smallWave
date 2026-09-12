#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build-cache/swift-modules
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift \
  SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift \
  SmallWave/Rendering/LiquidVolumeRenderer.swift Tests/MiniatureArtReview.swift \
  -o .build-cache/review-miniatures
exec .build-cache/review-miniatures "$@"
