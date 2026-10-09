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

# PTS index is the single navigation authority.
assert 'AVAssetReaderTrackOutput(track: track, outputSettings: nil)' in authority, 'Compressed-sample PTS enumeration missing'
assert 'rawPTS.sort { CMTimeCompare($0, $1) < 0 }' in authority, 'PTS list must be presentation-time sorted'
assert 'CMTimeCompare(previous, pts) == 0' in authority, 'Duplicate PTS removal missing'
assert 'let frames = uniquePTS.map(BestShotFramePTS.init)' in authority, 'Sorted unique PTS must feed the frame index'
assert 'isVariableFrameRate: timingIsVariable(uniquePTS)' in authority, 'VFR timing diagnosis missing'

# Exact-frame decode must never silently snap to a neighboring frame.
assert 'CMTimeCompare(actualTime, targetTime) == 0' in authority, 'Exact PTS equality gate missing'
assert 'exactFrameNotFound' in authority, 'Neighbor-frame fallback must fail explicitly'
assert 'kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange' in authority, 'HDR 10-bit decode surface missing'
assert 'kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange' in authority, 'SDR 8-bit decode surface missing'

# Synthetic VFR regression must exercise every indexed PTS and exact decoding.
assert 'Best-shot PTS authority runtime test: PASS' in test, 'B0-A runtime PASS marker missing'
assert 'Deliberately irregular presentation intervals' in test, 'Synthetic VFR source missing'
assert 'CMTimeCompare(indexed.time, expectedTime) == 0' in test, 'PTS index equality test missing'
assert 'decoded.isExactPTSMatch' in test, 'Exact decode equality test missing'
assert 'best-shot-b0a' in workflow, 'B0-A branch is not CI-enabled'
assert 'test_best_shot_frame_authority.swift' in workflow, 'B0-A runtime test is not wired into CI'

print('Best-shot B0-A static verification: PASS')
