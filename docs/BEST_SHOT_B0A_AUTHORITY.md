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

The authority is the sorted unique list of actual sample presentation timestamps (PTS), not nominal FPS and not a synthetic `1 / fps` grid.

## B0-A rules

1. Enumerate compressed video samples with `AVAssetReaderTrackOutput(... outputSettings: nil)`.
2. Collect valid sample PTS, sort by presentation time, and remove exact duplicates.
3. B1/B2 navigation must refer to a frame by its PTS-list ordinal.
4. When a frame is decoded, the decoded sample PTS must exactly equal the requested authority PTS.
5. Never silently substitute the nearest neighboring frame. A mismatch is an explicit diagnostic failure.
6. HLG/PQ sources request a 10-bit YCbCr decode surface; SDR/unknown currently request an 8-bit YCbCr surface.
7. B0-A stays feature-flagged OFF and disconnected from `ContentView` and `VideoAnalysisViewModel` until its gate passes.

## Automated gate

Synthetic VFR CI must verify:

- irregular source PTS are indexed in exact presentation order;
- every indexed PTS equals the source PTS;
- selected frames decode with exact PTS equality;
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
