#!/bin/sh
set -eu
mkdir -p .build-cache/swift-modules
swiftc -O -parse-as-library -module-cache-path .build-cache/swift-modules \
  Tests/OpticsCheck.swift -o .build-cache/test-optics
.build-cache/test-optics
