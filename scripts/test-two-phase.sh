#!/bin/sh
set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p .build-cache/swift-modules .build-cache/previews/two-phase
swiftc -O -module-cache-path .build-cache/swift-modules \
  Studies/TwoPhaseSimulation.swift Tests/TwoPhaseCoreCheck.swift \
  -o .build-cache/test-two-phase
.build-cache/test-two-phase
