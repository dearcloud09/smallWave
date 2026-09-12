# Smallwave — compact toy sailboat colorways

The latest user direction supersedes the earlier realistic model-boat study. The supplied blue/yellow/red wooden toy reference sets the short, wide bowl hull, low mast, one warm ivory cloth sail and small life ring. The three variants share exactly the same silhouette, texture alpha, scale and waterline.

## Delivered

- A / 마린 블루: blue painted hull, ivory stripe, red/ivory life ring. Default selection for new installs.
- B / 햇살 옐로: warm yellow paint, ivory stripe, red/ivory life ring. Strongest bright contrast against blue liquid at phone size.
- C / 브릭 레드: warm red paint, ivory stripe, navy/ivory life ring. A stronger small focal point.
- Existing Settings → 작은 배 menu selects all three. Saved raw selection IDs remain valid.
- `index.html`: comparison at 402 × 874 CSS pixels, with native app captures, five matching poses and three six-second motion clips.

The ImageGen-created RGBA asset is `SmallWave/Miniatures/toy-boat-blue.png`. It is a reference-inspired original cutout, without a studio background, floor shadow or baked water. One 512px premultiplied mip texture is shared at runtime (~1.3 MiB); shader material colors preserve the source grain and wear. The full original remains available for close inspection. Readable details are limited to wooden rim/grain, cloth weave/hem, one supporting rope/knot and one life ring. At the ~71pt hull width, the silhouette and material shading read first; fine grain/weave needs enlargement.

## Preserved

No art changes to liquid simulation, wave forces, gyro input, floating-body state, collision geometry, damping, liquid refraction or the existing contact cue. The image is intersected at the existing boat depth and follows its existing position/angle; lower hull pixels are viewed through liquid. The current source baseline was captured before this request's changes, rather than reusing the earlier realistic-boat baseline.

`source-invariants.json` records 11 boundary checks, including byte-identical simulation/input/volume files. `OceanView.swift` differs only in one art-picker section heading. `LiquidShaders.metal` differs only in `craftedMiniature`. Another concurrent task owns the timing instrumentation in `LiquidRenderer.swift` and `FrameTimingProbe.swift`; it is outside this art change. The art task changes only `loadMiniatureArt` in that renderer.

## Verification

| Check | Result | Evidence |
| --- | --- | --- |
| Simulator app build | PASS | 2026-09-12 22:00 BST art snapshot; `.build-cache/toy-ios-build.log` ends with BUILD SUCCEEDED. This validates the art snapshot, not subsequent concurrent project changes. |
| Existing UI selects all three colors | PASS | iPhone 17 Pro / iOS 26.5 Simulator; selected labels and native-blue/yellow/red.png |
| Repaint while paused | PASS | Yellow → red → blue selection retained `움직임 다시 시작` / play.fill after settings dismissal and repainted the boat |
| Same-state native rendering | PASS | 5 poses × 3 colors, plus procedural fallback, 804 × 1748 PNGs; `verification.json` |
| Motion state unchanged by art | PASS | 180 shared states × 3 colors; render-before/after state SHA assertions; `motion-trace.json`, `motion-summary.json` |
| Source/UI boundaries | PASS | `source-invariants.json` |
| Independent design/code review | PASS | Shared silhouette, readable color blocks, no observed alpha rectangle/halo or paint-mask leakage in 15 pose renders |
| Physical iPhone gyro feel/performance | NOT_RUN | Synthetic motion plus Simulator validation only; existing behavior reused |

Reproduce from the repo root with `sh scripts/review-miniatures.sh --output References/miniature-art-direction/toy-v2`. A Metal-capable local macOS execution environment is required. The optional `--stills-only` omits video. Generated screenshots/movies are comparison evidence, not test-time replacements for the real renderer.

The object is an image-based miniature with real in-app depth compositing. It does not reveal new 3D sides when the phone lies flat or rotates out of the image plane. No physical-device fluid performance improvement is claimed.
