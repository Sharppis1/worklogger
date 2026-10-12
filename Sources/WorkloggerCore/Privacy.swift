import Foundation

public struct ObservationEnvelope: Codable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let kind: ObservationKind
    public let activity: String
    public let source: String
    public let workTopic: String?

    enum CodingKeys: String, CodingKey {
        case id
        case occurredAt = "occurred_at"
        case kind
        case activity
        case source
        case workTopic = "work_topic"
    }
}

public struct CorrectionEnvelope: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let kind: OverrideKind
    public let topic: String?

    enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case effectiveFrom = "effective_from"
        case effectiveUntil = "effective_until"
        case kind
        case topic
    }
}

public struct PrivacyBoundary: Sendable {
    private let classifier: Classifier

    public init(classifier: Classifier) {
        self.classifier = classifier
    }

    public func localPrivacy(for observation: Observation) -> String {
        classifier.classify(observation: observation).state == .nonWork ? "private" : "work"
    }

    public func sanitize(_ observation: Observation, activeCorrection: ManualCorrection? = nil) -> ObservationEnvelope {
        let classification = classifier.classify(observation: observation, activeCorrection: activeCorrection)
        let isWork = classification.state == .work || classification.state == .meeting
        return ObservationEnvelope(
            id: observation.id,
            occurredAt: observation.occurredAt,
            kind: observation.kind,
            activity: isWork ? classification.state.rawValue : "private_activity",
            source: minimizedSource(observation.source),
            workTopic: isWork ? classification.topic : nil
        )
    }

    public func sanitize(_ correction: ManualCorrection) -> CorrectionEnvelope {
        CorrectionEnvelope(
            id: correction.id,
            createdAt: correction.createdAt,
            effectiveFrom: correction.effectiveFrom,
            effectiveUntil: correction.effectiveUntil,
            kind: correction.kind,
            topic: correction.topic
        )
    }

    private func minimizedSource(_ source: String) -> String {
        switch source {
        case "macos", "manual", "demo", "shell", "windows_guest", "calendar": source
        default: "integration"
        }
    }
}
