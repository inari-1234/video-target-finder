#!/usr/bin/env python3
from pathlib import Path

root = Path('.')
authority_path = root / 'VideoTargetFinder' / 'BestShotFrameAuthority.swift'
test_path = root / 'scripts' / 'test_best_shot_frame_authority.swift'
workflow_path = root / '.github' / 'workflows' / 'ios-build.yml'
project_path = root / 'project.yml'
content_path = root / 'VideoTargetFinder' / 'ContentView.swift'
view_model_path = root / 'VideoTargetFinder' / 'VideoAnalysisViewModel.swift'

assert authority_path.exists(), 'B0-A frame authority source missing'
assert test_path.exists(), 'B0-A runtime test missing'

authority = authority_path.read_text(encoding='utf-8')
test = test_path.read_text(encoding='utf-8')
workflow = workflow_path.read_text(encoding='utf-8')
project = project_path.read_text(encoding='utf-8')
content = content_path.read_text(encoding='utf-8')
view_model = view_model_path.read_text(encoding='utf-8')

# A-Freeze remains the production authority while B0-A is diagnostic-only.
assert 'MARKETING_VERSION: 0.32.0' in project, 'B0-A must not advance production marketing version yet'
assert 'CURRENT_PROJECT_VERSION: 35' in project, 'B0-A must remain pinned to A-Freeze Build35 until real-device gate'
assert 'static let frameAuthorityDiagnosticsEnabled = false' in authority, 'B0-A feature flag must default OFF'
assert 'BestShotFrameAuthority' not in content, 'B0-A must not enter the normal UI before its gate passes'
assert 'BestShotFrameAuthority' not in view_model, 'B0-A must not alter production recognition pipeline'

# PTS index is the single navigation authority. Encoded samples are read in decode order,
# filtered to displayable media payload, associated with sync anchors, then presentation-sorted.
assert 'AVAssetReaderTrackOutput(track: track, outputSettings: nil)' in authority, 'Compressed-sample PTS enumeration missing'
assert 'CMSampleBufferGetNumSamples(sample) > 0' in authority, 'Timing-only sample filter missing'
assert 'CMSampleBufferGetTotalSampleSize(sample) > 0' in authority, 'Zero-payload sample filter missing'
assert 'kCMSampleAttachmentKey_DoNotDisplay' in authority, 'Non-display sample filter missing'
assert 'kCMSampleAttachmentKey_NotSync' in authority, 'Sync-sample detection missing'
assert 'currentSyncPTS = pts' in authority, 'Decode anchor update missing'
assert 'records.sort { CMTimeCompare($0.pts, $1.pts) < 0 }' in authority, 'PTS list must be presentation-time sorted'
assert 'CMTimeCompare(previous.pts, record.pts) == 0' in authority, 'Duplicate PTS removal missing'
assert 'let frames = presentationTimes.map(BestShotFramePTS.init)' in authority, 'Sorted unique PTS must feed the frame index'
assert 'decodeStartPTS: decodeStarts' in authority, 'Sync decode anchors must be retained with the index'
assert 'isVariableFrameRate: timingIsVariable(presentationTimes)' in authority, 'VFR timing diagnosis missing'

# Exact-frame decode starts from a sync anchor and must never silently snap.
assert 'let decodeAnchor = try index.decodeStart(at: ordinal)' in authority, 'Exact decode must use the stored sync anchor'
assert 'reader.timeRange = CMTimeRange(start: startTime, duration: duration)' in authority, 'Sync-anchored decode range missing'
assert 'CMTimeCompare(actualTime, targetTime) == 0' in authority, 'Exact PTS equality gate missing'
assert 'CMTimeCompare(actualTime, targetTime) > 0' in authority, 'Presentation-order overshoot guard missing'
assert 'exactFrameNotFound' in authority, 'Neighbor-frame fallback must fail explicitly'
assert 'kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange' in authority, 'HDR 10-bit decode surface missing'
assert 'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange' in authority, 'SDR 8-bit decode surface missing'

# Synthetic VFR regression treats the encoded file PTS set as authority and proves every
# admitted PTS decodes back to exactly itself.
assert 'Best-shot PTS authority runtime test: PASS' in test, 'B0-A runtime PASS marker missing'
assert 'Deliberately irregular presentation intervals' in test, 'Synthetic VFR source missing'
assert 'containsExactPTS(index.frames, sourcePTS)' in test, 'Writer PTS membership regression missing'
assert 'CMTimeCompare(previous, current) < 0' in test, 'Strictly increasing authority PTS regression missing'
assert 'for ordinal in index.frames.indices' in test, 'Runtime test must decode every authoritative PTS'
assert 'decoded.isExactPTSMatch' in test, 'Exact decode equality test missing'
assert 'best-shot-b0a' in workflow, 'B0-A branch is not CI-enabled'
assert 'test_best_shot_frame_authority.swift' in workflow, 'B0-A runtime test is not wired into CI'

print('Best-shot B0-A static verification: PASS')
