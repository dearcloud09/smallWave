#!/bin/sh
set -eu
mkdir -p .build-cache/swift-modules
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift \
  SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift Tests/VolumeRayCheck.swift \
  -o .build-cache/test-volume-ray
.build-cache/test-volume-ray
