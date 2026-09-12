#!/bin/sh
set -eu

mkdir -p .build-cache/swift-modules
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift \
  SmallWave/Core/OceanStyle.swift \
  Tests/CoreTests.swift \
  -o .build-cache/test-core
.build-cache/test-core

swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift \
  SmallWave/App/MotionInputHistory.swift \
  Tests/MotionInputCheck.swift \
  -o .build-cache/test-motion-input
.build-cache/test-motion-input
