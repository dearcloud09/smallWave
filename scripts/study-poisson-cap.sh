#!/bin/sh
set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p .build-cache/swift-modules .build-cache/previews/poisson-cap
run=$(mktemp -d ".build-cache/previews/poisson-cap/run-$(date -u +%Y-%m-%dT%H-%M-%SZ)-XXXXXX")
inputs='SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift SmallWave/Rendering/LiquidShaders.metal Studies/PoissonCap.swift Studies/PoissonCap.metal Studies/PoissonCap.md Tests/PoissonCapStudy.swift scripts/study-poisson-cap.sh'
shasum -a 256 $inputs > "$run/inputs-before-compile.txt"
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift \
  SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift Studies/PoissonCap.swift Tests/PoissonCapStudy.swift \
  -o "$run/study-poisson-cap"
"$run/study-poisson-cap" "$run"
shasum -a 256 $inputs > "$run/inputs-after-run.txt"
cmp "$run/inputs-before-compile.txt" "$run/inputs-after-run.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$run/compile-freeze-verified-at.txt"
printf '%s\n' "PASS inputs unchanged from compilation through provenance: $run"
