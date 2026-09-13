#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 4 ]; then
  echo 'Usage: sh scripts/study-material-edge.sh snapshot.json new-output-directory [transport.metal] [--diagnostics]' >&2
  exit 2
fi
snapshot=$1
output=$2
[ -f "$snapshot" ] || { echo "Snapshot does not exist: $snapshot" >&2; exit 1; }
mkdir -p .build-cache/swift-modules
if [ -e "$output" ]; then
  echo "Refusing to replace existing output: $output" >&2
  exit 1
fi
swiftc -O -module-cache-path .build-cache/swift-modules \
  SmallWave/Core/LiquidSimulation.swift \
  SmallWave/Rendering/LiquidVolumeField.swift \
  SmallWave/Rendering/LiquidVolumeRenderer.swift \
  Studies/MaterialEdgeProbe.swift \
  -framework Metal -framework MetalKit -framework CoreGraphics -framework ImageIO -framework UniformTypeIdentifiers -framework CryptoKit \
  -o .build-cache/material-edge-probe
.build-cache/material-edge-probe "$@"
