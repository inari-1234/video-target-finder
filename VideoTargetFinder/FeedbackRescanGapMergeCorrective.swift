import Foundation

struct FeedbackMergeExistingSegment: Sendable, Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let isRejected: Bool
}

struct FeedbackRescanGapEvidence: Sendable, Equatable {
    let candidateStartTime: TimeInterval
    let candidateEndTime: TimeInterval
    let acceptedHitTimes: [TimeInterval]
    let hardNegativeTimes: [TimeInterval]
}

struct FeedbackRescanGapMergePolicy: Sendable, Equatable {
    let overlapTolerance: TimeInterval
    let maximumGapSpan: TimeInterval
    let minimumInteriorHitCount: Int
    let maximumInteriorHitlessSpan: TimeInterval
    let maximumMergedSegmentCount: Int
    let maximumMergedDuration: TimeInterval

    static let conservative = FeedbackRescanGapMergePolicy(
        overlapTolerance: 0.45,
        maximumGapSpan: 4.0,
        minimumInteriorHitCount: 2,
        maximumInteriorHitlessSpan: 1.25,
        maximumMergedSegmentCount: 3,
        maximumMergedDuration: 20.0
    )
}

enum FeedbackRescanGapMergeReason: String, Sendable, Equatable {
    case featureDisabled = "feature-disabled"
    case nonPositiveGap = "non-positive-gap"
    case candidateDoesNotCoverGap = "candidate-does-not-cover-gap"
    case gapTooLong = "gap-too-long"
    case rejectedSegmentBoundary = "rejected-segment-boundary"
    case rejectedSegmentVeto = "rejected-segment-veto"
    case hardNegativeVeto = "hard-negative-veto"
    case insufficientInteriorHits = "insufficient-interior-hits"
    case excessiveHitlessSpan = "excessive-hitless-span"
    case mergeLimitExceeded = "merge-limit-exceeded"
    case accepted = "accepted"
}

struct FeedbackRescanGapDecision: Sendable, Equatable {
    let leftSegmentID: UUID
    let rightSegmentID: UUID
    let gapStartTime: TimeInterval
    let gapEndTime: TimeInterval
    let gapSpan: TimeInterval
    let interiorHitCount: Int
    let maximumHitlessSpan: TimeInterval
    let hardNegativeTimes: [TimeInterval]
    let shouldMerge: Bool
    let reason: FeedbackRescanGapMergeReason
}

struct FeedbackRescanMergeGroup: Sendable, Equatable {
    let canonicalID: UUID
    let memberIDs: [UUID]
    let startTime: TimeInterval
    let endTime: TimeInterval
}

struct FeedbackRescanGapMergePlan: Sendable, Equatable {
    let groups: [FeedbackRescanMergeGroup]
    let remap: [UUID: UUID]
    let decisions: [FeedbackRescanGapDecision]
}

enum FeedbackRescanGapMergePlanner {
    static func plan(
        existing: [FeedbackMergeExistingSegment],
        evidence: FeedbackRescanGapEvidence,
        enabled: Bool,
        policy: FeedbackRescanGapMergePolicy = .conservative
    ) -> FeedbackRescanGapMergePlan {
        let sorted = existing.sorted {
            if abs($0.startTime - $1.startTime) > 0.000_001 {
                return $0.startTime < $1.startTime
            }
            return $0.id.uuidString < $1.id.uuidString
        }
        let relevant = sorted.filter {
            evidence.candidateStartTime <= $0.endTime + policy.overlapTolerance &&
            evidence.candidateEndTime >= $0.startTime - policy.overlapTolerance
        }

        guard relevant.count >= 2 else {
            return FeedbackRescanGapMergePlan(groups: [], remap: [:], decisions: [])
        }

        // A user-rejected existing segment anywhere inside the candidate is a hard veto for
        // this rescan candidate. Do not let another safe-looking gap within the same candidate
        // partially merge around a segment the user explicitly marked as a false detection.
        if relevant.contains(where: \.isRejected) {
            let decisions = zip(relevant, relevant.dropFirst()).map { left, right in
                rejectedCandidateDecision(left: left, right: right, evidence: evidence)
            }
            return FeedbackRescanGapMergePlan(groups: [], remap: [:], decisions: decisions)
        }

        var decisions: [FeedbackRescanGapDecision] = []
        var groups: [FeedbackRescanMergeGroup] = []
        var currentGroup: [FeedbackMergeExistingSegment] = [relevant[0]]

        func finalizeCurrentGroup() {
            guard currentGroup.count >= 2 else { return }
            let canonical = currentGroup[0]
            groups.append(
                FeedbackRescanMergeGroup(
                    canonicalID: canonical.id,
                    memberIDs: currentGroup.map(\.id),
                    startTime: currentGroup.map(\.startTime).min() ?? canonical.startTime,
                    endTime: currentGroup.map(\.endTime).max() ?? canonical.endTime
                )
            )
        }

        for index in 1..<relevant.count {
            let left = relevant[index - 1]
            let right = relevant[index]
            var decision = evaluateGap(
                left: left,
                right: right,
                evidence: evidence,
                enabled: enabled,
                policy: policy
            )

            if decision.shouldMerge {
                let proposedMembers: [FeedbackMergeExistingSegment]
                if currentGroup.last?.id == left.id {
                    proposedMembers = currentGroup + [right]
                } else {
                    finalizeCurrentGroup()
                    currentGroup = [left]
                    proposedMembers = [left, right]
                }

                let proposedStart = proposedMembers.map(\.startTime).min() ?? left.startTime
                let proposedEnd = proposedMembers.map(\.endTime).max() ?? right.endTime
                if proposedMembers.count > policy.maximumMergedSegmentCount ||
                    proposedEnd - proposedStart > policy.maximumMergedDuration {
                    decision = FeedbackRescanGapDecision(
                        leftSegmentID: decision.leftSegmentID,
                        rightSegmentID: decision.rightSegmentID,
                        gapStartTime: decision.gapStartTime,
                        gapEndTime: decision.gapEndTime,
                        gapSpan: decision.gapSpan,
                        interiorHitCount: decision.interiorHitCount,
                        maximumHitlessSpan: decision.maximumHitlessSpan,
                        hardNegativeTimes: decision.hardNegativeTimes,
                        shouldMerge: false,
                        reason: .mergeLimitExceeded
                    )
                    finalizeCurrentGroup()
                    currentGroup = [right]
                } else {
                    currentGroup = proposedMembers
                }
            } else {
                finalizeCurrentGroup()
                currentGroup = [right]
            }
            decisions.append(decision)
        }
        finalizeCurrentGroup()

        var remap: [UUID: UUID] = [:]
        for group in groups {
            for id in group.memberIDs where id != group.canonicalID {
                remap[id] = group.canonicalID
            }
        }

        return FeedbackRescanGapMergePlan(
            groups: groups,
            remap: remap,
            decisions: decisions
        )
    }

    private static func rejectedCandidateDecision(
        left: FeedbackMergeExistingSegment,
        right: FeedbackMergeExistingSegment,
        evidence: FeedbackRescanGapEvidence
    ) -> FeedbackRescanGapDecision {
        let gapStart = left.endTime
        let gapEnd = right.startTime
        let epsilon: TimeInterval = 0.001
        let interiorHits = evidence.acceptedHitTimes
            .filter { $0 > gapStart + epsilon && $0 < gapEnd - epsilon }
            .sorted()
        let hardNegatives = evidence.hardNegativeTimes
            .filter { $0 > gapStart + epsilon && $0 < gapEnd - epsilon }
            .sorted()
        return FeedbackRescanGapDecision(
            leftSegmentID: left.id,
            rightSegmentID: right.id,
            gapStartTime: gapStart,
            gapEndTime: gapEnd,
            gapSpan: max(0, gapEnd - gapStart),
            interiorHitCount: interiorHits.count,
            maximumHitlessSpan: maxHitlessSpan(
                gapStart: gapStart,
                gapEnd: gapEnd,
                interiorHits: interiorHits
            ),
            hardNegativeTimes: hardNegatives,
            shouldMerge: false,
            reason: .rejectedSegmentVeto
        )
    }

    private static func evaluateGap(
        left: FeedbackMergeExistingSegment,
        right: FeedbackMergeExistingSegment,
        evidence: FeedbackRescanGapEvidence,
        enabled: Bool,
        policy: FeedbackRescanGapMergePolicy
    ) -> FeedbackRescanGapDecision {
        let gapStart = left.endTime
        let gapEnd = right.startTime
        let gapSpan = gapEnd - gapStart
        let epsilon: TimeInterval = 0.001
        let interiorHits = evidence.acceptedHitTimes
            .filter { $0 > gapStart + epsilon && $0 < gapEnd - epsilon }
            .sorted()
        let hardNegatives = evidence.hardNegativeTimes
            .filter { $0 > gapStart + epsilon && $0 < gapEnd - epsilon }
            .sorted()
        let maximumHitlessSpan = maxHitlessSpan(
            gapStart: gapStart,
            gapEnd: gapEnd,
            interiorHits: interiorHits
        )

        func result(_ shouldMerge: Bool, _ reason: FeedbackRescanGapMergeReason) -> FeedbackRescanGapDecision {
            FeedbackRescanGapDecision(
                leftSegmentID: left.id,
                rightSegmentID: right.id,
                gapStartTime: gapStart,
                gapEndTime: gapEnd,
                gapSpan: max(0, gapSpan),
                interiorHitCount: interiorHits.count,
                maximumHitlessSpan: maximumHitlessSpan,
                hardNegativeTimes: hardNegatives,
                shouldMerge: shouldMerge,
                reason: reason
            )
        }

        guard enabled else { return result(false, .featureDisabled) }
        guard gapSpan > epsilon else { return result(false, .nonPositiveGap) }
        guard evidence.candidateStartTime <= gapStart + policy.overlapTolerance,
              evidence.candidateEndTime >= gapEnd - policy.overlapTolerance else {
            return result(false, .candidateDoesNotCoverGap)
        }
        guard gapSpan <= policy.maximumGapSpan else { return result(false, .gapTooLong) }
        guard !left.isRejected, !right.isRejected else { return result(false, .rejectedSegmentBoundary) }
        guard hardNegatives.isEmpty else { return result(false, .hardNegativeVeto) }
        guard interiorHits.count >= policy.minimumInteriorHitCount else {
            return result(false, .insufficientInteriorHits)
        }
        guard maximumHitlessSpan <= policy.maximumInteriorHitlessSpan + epsilon else {
            return result(false, .excessiveHitlessSpan)
        }
        return result(true, .accepted)
    }

    private static func maxHitlessSpan(
        gapStart: TimeInterval,
        gapEnd: TimeInterval,
        interiorHits: [TimeInterval]
    ) -> TimeInterval {
        guard gapEnd > gapStart else { return 0 }
        guard !interiorHits.isEmpty else { return gapEnd - gapStart }
        var maximum = max(0, interiorHits[0] - gapStart)
        for index in 1..<interiorHits.count {
            maximum = max(maximum, interiorHits[index] - interiorHits[index - 1])
        }
        maximum = max(maximum, gapEnd - (interiorHits.last ?? gapStart))
        return maximum
    }
}

struct SegmentIDRemapTable: Sendable, Equatable {
    private(set) var direct: [UUID: UUID] = [:]

    mutating func register(_ updates: [UUID: UUID]) {
        for (source, destination) in updates {
            let resolvedDestination = resolve(destination)
            let resolvedSource = resolve(source)
            guard resolvedSource != resolvedDestination else { continue }
            direct[resolvedSource] = resolvedDestination
            direct[source] = resolvedDestination
        }
        compress()
    }

    func resolve(_ id: UUID) -> UUID {
        var current = id
        var visited = Set<UUID>()
        while let next = direct[current], next != current, !visited.contains(current) {
            visited.insert(current)
            current = next
        }
        return current
    }

    mutating func reset() {
        direct.removeAll(keepingCapacity: false)
    }

    private mutating func compress() {
        for key in Array(direct.keys) {
            direct[key] = resolve(key)
        }
    }
}

struct LearnedReferenceIdentity: Sendable, Equatable {
    let id: UUID
    let sourceSegmentID: UUID
    let sourceTime: TimeInterval
}

enum MergedLearnedReferenceIdentityPolicy {
    static func retainedForMergedCanonicals(
        _ references: [LearnedReferenceIdentity],
        affectedCanonicalIDs: Set<UUID>,
        remap: SegmentIDRemapTable
    ) -> [LearnedReferenceIdentity] {
        references.compactMap { reference in
            let canonicalID = remap.resolve(reference.sourceSegmentID)
            guard affectedCanonicalIDs.contains(canonicalID) else { return nil }
            return LearnedReferenceIdentity(
                id: reference.id,
                sourceSegmentID: canonicalID,
                sourceTime: reference.sourceTime
            )
        }
    }

    static func removingRejectedCanonical(
        _ rejectedCanonicalID: UUID,
        from references: [LearnedReferenceIdentity],
        remap: SegmentIDRemapTable
    ) -> [LearnedReferenceIdentity] {
        let rejected = remap.resolve(rejectedCanonicalID)
        return references.filter {
            remap.resolve($0.sourceSegmentID) != rejected
        }.map {
            LearnedReferenceIdentity(
                id: $0.id,
                sourceSegmentID: remap.resolve($0.sourceSegmentID),
                sourceTime: $0.sourceTime
            )
        }
    }
}

enum ContinuityCorrectiveFeatureFlags {
    // Corrective 1. A/B comparison can call the planner with enabled=false without changing runtime policy.
    static let feedbackRescanGapMerge = true
    // Corrective 2 is intentionally not connected yet.
    static let initialTierCBridge = false
}
