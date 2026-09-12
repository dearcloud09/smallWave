#!/bin/sh
set -eu
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p .build-cache/swift-modules .build-cache/previews/two-phase-motion
swiftc -O -module-cache-path .build-cache/swift-modules \
  Studies/TwoPhaseSimulation.swift Tests/TwoPhaseMotionStudy.swift \
  -o .build-cache/study-two-phase-motion
.build-cache/study-two-phase-motion
