#!/bin/sh
set -eu
mkdir -p .build-cache/swift-modules
swiftc -O -D RESOLUTION_STUDY -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift \
  SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift Studies/ContourVolumeRenderer.swift Studies/VolumeRayRenderer.swift \
  Tests/CoalescenceStudy.swift Tests/OpticalResolutionStudy.swift \
  -o .build-cache/study-optical-resolution
.build-cache/study-optical-resolution "$@"
