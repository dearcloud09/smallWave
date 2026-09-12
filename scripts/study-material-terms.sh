#!/bin/sh
set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p .build-cache/swift-modules .build-cache/previews/material-terms
run=$(mktemp -d ".build-cache/previews/material-terms/run-$(date -u +%Y-%m-%dT%H-%M-%SZ)-XXXXXX")
inputs='SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift SmallWave/Rendering/LiquidShaders.metal Studies/MaterialTerms.swift Studies/MaterialTerms.md Tests/MaterialTermsStudy.swift scripts/study-material-terms.sh'
shasum -a 256 $inputs > "$run/inputs-before-compile.txt"
swiftc -O -module-cache-path .build-cache/swift-modules SmallWave/Core/LiquidSimulation.swift SmallWave/Core/OceanStyle.swift SmallWave/Rendering/LiquidRenderer.swift SmallWave/Rendering/LiquidVolumeField.swift SmallWave/Rendering/LiquidVolumeRenderer.swift Studies/MaterialTerms.swift Tests/MaterialTermsStudy.swift -o "$run/study-material-terms"
poisson=$(find .build-cache/previews/poisson-cap -name shake-baseline.png -type f -print 2>/dev/null | sort | tail -n 1)
test -n "$poisson"
"$run/study-material-terms" "$run" "$poisson"
shasum -a 256 $inputs > "$run/inputs-after-run.txt"
cmp "$run/inputs-before-compile.txt" "$run/inputs-after-run.txt"
date -u +%Y-%m-%dT%H:%M:%SZ > "$run/compile-freeze-verified-at.txt"
printf '%s\n' "PASS inputs unchanged from compilation through provenance: $run"
