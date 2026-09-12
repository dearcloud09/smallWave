#!/bin/sh
set -eu
python3 Studies/prepare_resolution_study.py
mkdir -p .build-cache/swift-modules
for variant in coarse fine; do
  swiftc -O -module-cache-path .build-cache/swift-modules \
    ".build-cache/resolution/$variant/LiquidSimulation.swift" \
    SmallWave/Core/OceanStyle.swift \
    ".build-cache/resolution/$variant/LiquidRenderer.swift" \
    SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift \
    Tests/ResolutionStudy.swift -o ".build-cache/resolution/$variant/run"
  SMALLWAVE_RESOLUTION="$variant" ".build-cache/resolution/$variant/run"
done
swiftc -parse-as-library -O -module-cache-path .build-cache/swift-modules \
  Tests/CompareResolution.swift -o .build-cache/resolution/compare
.build-cache/resolution/compare
