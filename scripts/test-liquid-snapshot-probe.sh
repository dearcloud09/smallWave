#!/bin/sh
set -eu

mkdir -p .build-cache/swift-modules .build-cache/liquid-snapshot-probe-check
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Rendering/LiquidSnapshotProbe.swift Tests/LiquidSnapshotProbeCheck.swift \
  -o .build-cache/liquid-snapshot-probe-check/test-liquid-snapshot-probe
.build-cache/liquid-snapshot-probe-check/test-liquid-snapshot-probe
