#!/bin/sh
set -eu

mkdir -p .build-cache/swift-modules .build-cache/rest-surface-check
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Rendering/LiquidVolumeField.swift Tests/LiquidSurfaceRestCheck.swift \
  -o .build-cache/rest-surface-check/test-rest-surface
.build-cache/rest-surface-check/test-rest-surface
