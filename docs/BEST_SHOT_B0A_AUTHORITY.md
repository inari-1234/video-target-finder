# Best Shot / High-Quality Still Image — B0-A Authority

Reference date: 2026-10-09

## A-Freeze

The B-series starts from the latest fully-qualified A-series candidate without modifying `main` or the existing candidate branch.

- Freeze branch: `a-freeze-v0.32-build35-diag2`
- Freeze SHA: `f75ef0f56c7f1161826f8a695eca80b9d5508801`
- App version at freeze: `0.32.0`
- Build: `35`
- Full CI: Run `37867782711` / success
- B-series work branch: `best-shot-b0a`

The best-shot subsystem may read A-series results later, but must not write back into production recognition logic.

## B0-A purpose

Establish one authoritative notion of a video frame before any still-image UI or quality ranking is implemented.

The navigation authority is the sorted unique list of actual **displayable encoded video sample presentation timestamps (PTS)**, not nominal FPS and not a synthetic `1 / fps` grid.

## B0-A rules

1. Enumerate compressed video samples with `AVAssetReaderTrackOutput(... outputSettings: nil)`. These samples arrive in decode order.
2. Exclude timing-only / zero-payload samples and samples marked `DoNotDisplay`.
3. While decode order is still available, associate each admitted frame with the nearest preceding sync sample (`NotSync == false`).
4. Sort admitted frames by presentation PTS and remove exact duplicate PTS values.
5. B1/B2 navigation refers to a frame only by this presentation-PTS-list ordinal.
6. To decode one selected frame, begin reading from its stored sync anchor and advance decoded presentation-order output until the exact target PTS is reached.
7. The decoded sample PTS must exactly equal the requested authority PTS. Never silently substitute the nearest neighboring frame.
8. HLG/PQ sources request a 10-bit YCbCr decode surface; SDR/unknown currently request an 8-bit YCbCr surface.
9. B0-A stays feature-flagged OFF and disconnected from `ContentView` and `VideoAnalysisViewModel` until its gate passes.

## Why sync anchors are required

A compressed H.264/HEVC track can contain inter-frame dependencies and B-frame reordering. Starting a decoded read directly at an arbitrary presentation PTS is therefore not a reliable exact-frame contract. B0-A keeps navigation presentation-based while retaining the minimum decode-history information needed to reproduce that frame.

## Automated gate

Synthetic VFR CI must verify:

- the writer's intended source PTS values remain represented in the encoded presentation index;
- the final authority index is strictly increasing after presentation-time sorting and deduplication;
- every PTS admitted into the authority index can be decoded from its sync anchor back to exactly the same PTS;
- VFR is detected from actual timing rather than nominal FPS;
- HDR and SDR choose different decode-surface bit depths;
- the existing A-series static/runtime/build/IPA regression remains green.

## Real-device gate (required before B0-A PASS)

B0-A is not final PASS on CI alone. The later diagnostic surface must collect real-device evidence from representative sources, including at minimum:

- ordinary SDR camera video;
- VFR camera video where available;
- HDR/HLG or Dolby Vision source;
- rotated portrait video;
- Photos-edited/current representation if used by the app.

For each source, sampled authority PTS must decode to the same PTS with a target match rate of 100%. HDR/SDR metadata, pixel format, orientation, and any color conversion must be recorded. Color-fidelity thresholds will be frozen only after the diagnostic path can measure them consistently.

## Current status

B0-A foundation implementation in progress. CI PASS is necessary but not sufficient; real-device evidence remains a separate gate.
