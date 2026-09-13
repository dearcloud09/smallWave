#!/usr/bin/env python3
"""Validate one developer wall capture and emit replayable frozen-frame JSON files."""
import argparse
import hashlib
import json
import math
import re
import sys
from pathlib import Path


CAPTURE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")


def fail(message):
    raise ValueError(message)


def load_json(raw):
    def reject_constant(value):
        fail(f"non-finite JSON constant: {value}")
    return json.loads(raw, parse_constant=reject_constant)


def finite(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f"{name} must be finite")
    try:
        valid = math.isfinite(value)
    except OverflowError:
        valid = False
    if not valid:
        fail(f"{name} must be finite")
    return value


def vector(value, count, name):
    if not isinstance(value, list) or len(value) != count:
        fail(f"{name} must have {count} values")
    return [finite(item, f"{name}[{index}]") for index, item in enumerate(value)]


def object_value(value, name):
    if not isinstance(value, dict):
        fail(f"{name} must be an object")
    return value


def validate_every_number(value, name="root"):
    if isinstance(value, float) and not math.isfinite(value):
        fail(f"{name} is non-finite")
    if isinstance(value, list):
        for index, item in enumerate(value):
            validate_every_number(item, f"{name}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            validate_every_number(item, f"{name}.{key}")


def validate_snapshot(snapshot, index):
    item = object_value(snapshot, f"snapshots[{index}]")
    for key in ("targetSeconds", "elapsedSeconds", "simulationTime", "energy", "screenRotation"):
        finite(item.get(key), f"snapshots[{index}].{key}")
    particles = item.get("particles")
    bubbles = item.get("bubbles")
    if not isinstance(particles, list) or not isinstance(bubbles, list):
        fail(f"snapshots[{index}] particles/bubbles must be arrays")
    if not 1 <= len(particles) <= 4096 or len(bubbles) > 36:
        fail(f"snapshots[{index}] particle/bubble count exceeds replay limits")
    for particle_index, particle in enumerate(particles):
        particle = object_value(particle, f"particles[{particle_index}]")
        vector(particle.get("position"), 3, f"particles[{particle_index}].position")
        vector(particle.get("velocity"), 3, f"particles[{particle_index}].velocity")
    for bubble_index, bubble in enumerate(bubbles):
        bubble = object_value(bubble, f"bubbles[{bubble_index}]")
        vector(bubble.get("position"), 3, f"bubbles[{bubble_index}].position")
        finite(bubble.get("radius"), f"bubbles[{bubble_index}].radius")
        finite(bubble.get("life"), f"bubbles[{bubble_index}].life")
    boat = object_value(item.get("boat"), f"snapshots[{index}].boat")
    vector(boat.get("position"), 3, f"snapshots[{index}].boat.position")
    vector(boat.get("velocity"), 3, f"snapshots[{index}].boat.velocity")
    for key in ("angle", "angularVelocity", "immersion"):
        finite(boat.get(key), f"snapshots[{index}].boat.{key}")
    vector(item.get("gravity"), 3, f"snapshots[{index}].gravity")
    vector(item.get("safeAcceleration"), 3, f"snapshots[{index}].safeAcceleration")
    vector(item.get("surfaceFilter"), 4, f"snapshots[{index}].surfaceFilter")
    state = object_value(item.get("renderState"), f"snapshots[{index}].renderState")
    for key in ("viewport", "movement", "color", "optics", "miniatureArt", "boat"):
        vector(state.get(key), 4, f"snapshots[{index}].renderState.{key}")
    for key in ("targetPixelWidth", "targetPixelHeight"):
        value = state.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 5000:
            fail(f"snapshots[{index}].renderState.{key} must be an integer in 1...5000")
    return item


def validate_capture(capture, expected_build, expected_capture):
    capture = object_value(capture, "capture")
    validate_every_number(capture)
    if capture.get("schemaVersion") != 2:
        fail("schemaVersion must be 2")
    if str(capture.get("appBuild")) != expected_build:
        fail("appBuild differs from --expected-build")
    if capture.get("captureID") != expected_capture:
        fail("captureID differs from --expected-capture")
    if not CAPTURE_ID.fullmatch(expected_capture):
        fail("--expected-capture is invalid")
    finite(capture.get("durationSeconds"), "durationSeconds")
    spacing = finite(capture.get("spacing"), "spacing")
    if spacing <= 0:
        fail("spacing must be positive")
    finite(capture.get("smoothingRadius"), "smoothingRadius")
    bounds = object_value(capture.get("bounds"), "bounds")
    for key in ("halfWidth", "halfHeight", "halfDepth"):
        if finite(bounds.get(key), f"bounds.{key}") <= 0:
            fail(f"bounds.{key} must be positive")
    snapshots = capture.get("snapshots")
    if not isinstance(snapshots, list) or not snapshots or len(snapshots) > 9:
        fail("snapshots must contain 1...9 entries")
    checked = [validate_snapshot(snapshot, index) for index, snapshot in enumerate(snapshots)]
    elapsed = [snapshot["elapsedSeconds"] for snapshot in checked]
    if any(right <= left for left, right in zip(elapsed, elapsed[1:])):
        fail("snapshot elapsedSeconds must be strictly chronological")
    return capture, checked, spacing


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--expected-build", required=True)
    parser.add_argument("--expected-capture", required=True)
    args = parser.parse_args()
    if args.output.exists():
        fail(f"refusing existing output: {args.output}")
    raw = args.capture.read_bytes()
    capture, snapshots, spacing = validate_capture(load_json(raw), args.expected_build, args.expected_capture)
    args.output.mkdir(parents=True)
    outputs = []
    for index, snapshot in enumerate(snapshots):
        frame = {
            "particles": snapshot["particles"], "bubbles": snapshot["bubbles"],
            "renderRadius": spacing * 1.5, "spacing": spacing,
            "summary": {"time": snapshot["simulationTime"], "energy": snapshot["energy"], "boat": snapshot["boat"]},
            "gravity": snapshot["gravity"], "safeAcceleration": snapshot["safeAcceleration"],
            "surfaceFilter": snapshot["surfaceFilter"], "renderState": snapshot["renderState"],
        }
        name = f"{index:03d}.json"
        data = json.dumps(frame, indent=2, sort_keys=True, allow_nan=False).encode() + b"\n"
        (args.output / name).write_bytes(data)
        outputs.append({"file": name, "sha256": sha256_bytes(data),
                        "elapsedSeconds": snapshot["elapsedSeconds"], "targetSeconds": snapshot["targetSeconds"]})
    manifest = {"schemaVersion": 1, "sourceSHA256": sha256_bytes(raw), "captureID": capture["captureID"],
                "appBuild": capture["appBuild"], "frames": outputs}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True, allow_nan=False) + "\n", encoding="utf-8")
    print(f"PASS {len(outputs)} frames -> {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
