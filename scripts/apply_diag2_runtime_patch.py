#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
vm_path = ROOT / "VideoTargetFinder" / "VideoAnalysisViewModel.swift"
project_path = ROOT / "project.yml"
verify_path = ROOT / "scripts" / "verify_source.py"
runtime_payload = (ROOT / "scripts" / "diag2_runtime_block.txt").read_text(encoding="utf-8")
merge_payload = (ROOT / "scripts" / "diag2_merge_block.txt").read_text(encoding="utf-8")

vm = vm_path.read_text(encoding="utf-8")
marker = "DIAG-2 shadow bridge runtime diagnostics"
if marker not in vm:
    start = vm.index("    private func buildSegments(")
    end = vm.index("    private func continuityTrackingSeed(", start)
    vm = vm[:start] + runtime_payload + vm[end:]

    merge_start = vm.index("    private func mergeFeedbackRescanSegments(")
    merge_end = vm.index("    private func makeDetailWindows(", merge_start)
    vm = vm[:merge_start] + merge_payload + vm[merge_end:]

    call_start = vm.index("                let rescannedSegments = try await self.buildSegments(")
    call_end = vm.index("                let merged = self.mergeFeedbackRescanSegments(", call_start)
    call = vm[call_start:call_end]
    old_tail = "                    sensitivity: selectedSensitivity\n                )\n"
    new_tail = (
        "                    sensitivity: selectedSensitivity,\n"
        "                    diagnosticStage: \"feedback-rescan\",\n"
        "                    discoverySource: .feedbackRescan\n"
        "                )\n"
    )
    assert call.count(old_tail) == 1, "Feedback-rescan buildSegments call shape changed"
    call = call.replace(old_tail, new_tail)
    vm = vm[:call_start] + call + vm[call_end:]
    vm_path.write_text(vm, encoding="utf-8")
else:
    print("DIAG-2 runtime patch already applied")

project = project_path.read_text(encoding="utf-8")
if "CURRENT_PROJECT_VERSION: 34" in project:
    project = project.replace("CURRENT_PROJECT_VERSION: 34", "CURRENT_PROJECT_VERSION: 35", 1)
elif "CURRENT_PROJECT_VERSION: 35" not in project:
    raise AssertionError("Unexpected project build number")
project_path.write_text(project, encoding="utf-8")

verify = verify_path.read_text(encoding="utf-8")
old_build_assert = 'assert re.search(r"CURRENT_PROJECT_VERSION:\\s*34", project), "Build 34 missing"'
new_build_assert = 'assert re.search(r"CURRENT_PROJECT_VERSION:\\s*35", project), "Build 35 missing"'
if old_build_assert in verify:
    verify = verify.replace(old_build_assert, new_build_assert, 1)
elif new_build_assert not in verify:
    raise AssertionError("Build assertion shape changed")

verify_marker = "# DIAG-2 shadow bridge / rescan merge diagnostic qualification"
if verify_marker not in verify:
    verify += f'''\n\n{verify_marker}\nshadow_diag = Path("VideoTargetFinder/SegmentBridgeShadowDiagnostics.swift").read_text(encoding="utf-8")\nmerge_diag = Path("VideoTargetFinder/SegmentFeedbackMergeDiagnostics.swift").read_text(encoding="utf-8")\nassert Path("scripts/test_diag2_shadow_bridge.swift").exists(), "DIAG-2 shadow bridge regression missing"\nassert Path("scripts/test_diag2_rescan_merge.swift").exists(), "DIAG-2 rescan merge regression missing"\nassert "defaultShadowHorizon: TimeInterval = 6.0" in shadow_diag, "DIAG-2 shadow horizon must remain diagnostic-only at 6 s"\nassert "min(2.25, tolerated + 1.0)" in pipeline_core, "Production visual bridge ceiling must remain 2.25 s"\nassert "bridge-pair stage=%@" in view_model, "DIAG-2 pair identity log missing"\nassert "boundaryGap=%.3fs hitGap=%.3fs" in view_model, "DIAG-2 boundary/hit gap distinction missing"\nassert "visual-continuity-candidate" in view_model, "Visual evidence log semantic missing"\nassert "bridge-shadow-pass" in view_model and "bridge-shadow-fail" in view_model, "Shadow decision logs missing"\nassert "bridge-applied" in view_model, "Applied bridge log missing"\nassert "Segment continuity bridge confirmed" not in view_model, "Misleading pre-application bridge confirmation log returned"\nassert 'diagnosticStage: "feedback-rescan"' in view_model, "Feedback-rescan diagnostic stage missing"\nassert "discoverySource: .feedbackRescan" in view_model, "Feedback-rescan source tagging missing before merge"\nassert "feedback-rescan-merge-discarded stage=final/merge" in view_model, "Rescan discard diagnostic missing"\nassert "spansMultipleExistingSegments" in merge_diag, "Cross-existing-segment rescan diagnostic missing"\n'''
verify_path.write_text(verify, encoding="utf-8")

print("DIAG-2 runtime patch prepared")
