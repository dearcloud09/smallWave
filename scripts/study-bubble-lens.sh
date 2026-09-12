#!/bin/sh
set -eu
mkdir -p .build-cache/swift-modules
swiftc -O -D RESOLUTION_STUDY -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift \
  SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift Studies/ContourVolumeRenderer.swift \
  Studies/VolumeRayRenderer.swift Studies/BubbleLensRenderer.swift \
  Tests/CoalescenceStudy.swift Tests/BubbleLensStudy.swift \
  -o .build-cache/study-bubble-lens
.build-cache/study-bubble-lens
