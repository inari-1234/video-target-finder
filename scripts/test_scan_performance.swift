import Foundation

@main
enum ScanPerformanceDiagnosticsTests {
    static func main() {
        precondition(ScanPerformanceThermalLevel.peak(.nominal, .serious) == .serious)
        precondition(ScanPerformanceThermalLevel.peak(.critical, .fair) == .critical)
        precondition(ScanPerformanceThermalLevel.peak(.unknown, .nominal) == .nominal)

        let coarse = ScanPhasePerformanceSummary(
            phase: .coarse,
            elapsedSeconds: 20,
            sampleCount: 100,
            outputCount: 18,
            thermalPeak: .fair
        )
        precondition(abs((coarse.samplesPerSecond ?? 0) - 5.0) < 0.0001)
        precondition(coarse.phase.outputLabel == "候補")

        let detail = ScanPhasePerformanceSummary(
            phase: .detail,
            elapsedSeconds: 10,
            sampleCount: 50,
            outputCount: 12,
            thermalPeak: .serious
        )
        let run = ScanPerformanceRunSummary(
            kind: .feedbackRescan,
            runNumber: 2,
            phases: [coarse, detail]
        )
        precondition(run.id == "feedbackRescan-2")
        precondition(run.title == "学習再探索 #2")
        precondition(abs(run.totalElapsedSeconds - 30) < 0.0001)
        precondition(run.peakThermalLevel == .serious)

        precondition(
            ScanPerformanceAnalyzer.detailSampleCount(span: 1.0, interval: 0.25) == 5
        )
        precondition(
            ScanPerformanceAnalyzer.detailSampleCount(span: 0.26, interval: 0.25) == 2
        )
        precondition(
            ScanPerformanceAnalyzer.detailSampleCount(span: 0.0, interval: 0.25) == 1
        )
        precondition(
            ScanPerformanceAnalyzer.detailSampleCount(span: 1.0, interval: 0) == 0
        )

        print("ScanPerformanceDiagnostics tests: PASS")
    }
}
