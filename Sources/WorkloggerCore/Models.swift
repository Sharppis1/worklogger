import Foundation

public enum WorkState: String, Codable, CaseIterable, Sendable {
    case work
    case meeting
    case uncertain
    case nonWork = "non_work"
    case breakTime = "break"
    case paused = "tracking_paused"

    public var label: String {
        switch self {
        case .work: "Work"
        case .meeting: "Meeting"
        case .uncertain: "Uncertain"
        case .nonWork: "Non-work"
        case .breakTime: "Break"
        case .paused: "Tracking paused"
        }
    }

    public var symbol: String {
        switch self {
        case .work: "briefcase.fill"
        case .meeting: "person.2.fill"
        case .uncertain: "questionmark.diamond.fill"
        case .nonWork: "house.fill"
        case .breakTime: "cup.and.saucer.fill"
        case .paused: "pause.circle.fill"
        }
    }
}

public enum ObservationKind: String, Codable, Sendable {
    case activeApplication = "active_application"
    case idle
    case screenLocked = "screen_locked"
    case screenUnlocked = "screen_unlocked"
    case sleep
    case wake
    case browserHost = "browser_host"
    case repositoryContext = "repository_context"
    case windowsGuest = "windows_guest"
    case calendarIntent = "calendar_intent"
    case manual
}

public struct Observation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let occurredAt: Date
    public let kind: ObservationKind
    public let source: String
    public let application: String?
    public let bundleIdentifier: String?
    public let host: String?
    public let repository: String?
    public let calendar: CalendarEvent?
    public let idleSeconds: TimeInterval?

    public init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        kind: ObservationKind,
        source: String,
        application: String? = nil,
        bundleIdentifier: String? = nil,
        host: String? = nil,
        repository: String? = nil,
        calendar: CalendarEvent? = nil,
        idleSeconds: TimeInterval? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.source = source
        self.application = application
        self.bundleIdentifier = bundleIdentifier
        self.host = host
        self.repository = repository
        self.calendar = calendar
        self.idleSeconds = idleSeconds
    }
}

public struct CalendarEvent: Codable, Equatable, Sendable {
    public let id: String
    public let titleCategory: String?
    public let startsAt: Date
    public let endsAt: Date
    public let isBlocking: Bool

    public init(id: String, titleCategory: String?, startsAt: Date, endsAt: Date, isBlocking: Bool) {
        self.id = id
        self.titleCategory = titleCategory
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isBlocking = isBlocking
    }
}

public protocol CalendarIntentProviding: Sendable {
    func events(from: Date, to: Date) async throws -> [CalendarEvent]
}

public struct Classification: Codable, Equatable, Sendable {
    public let state: WorkState
    public let topic: String?
    public let source: String
    public let confidence: Double
    public let reason: String

    public init(state: WorkState, topic: String? = nil, source: String, confidence: Double, reason: String) {
        self.state = state
        self.topic = topic
        self.source = source
        self.confidence = confidence
        self.reason = reason
    }
}

public enum OverrideKind: String, Codable, Sendable {
    case markWork = "mark_work"
    case topic
    case breakTime = "break"
    case paperPlanning = "paper_planning"
    case pause
    case resume
    case previousIntervalWork = "previous_interval_work"
}

public struct ManualCorrection: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let effectiveFrom: Date
    public let effectiveUntil: Date?
    public let kind: OverrideKind
    public let topic: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        effectiveFrom: Date,
        effectiveUntil: Date?,
        kind: OverrideKind,
        topic: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.effectiveFrom = effectiveFrom
        self.effectiveUntil = effectiveUntil
        self.kind = kind
        self.topic = topic
    }

    public func isActive(at date: Date) -> Bool {
        effectiveFrom <= date && (effectiveUntil == nil || date < effectiveUntil!)
    }
}

public struct DailyTotals: Equatable, Sendable {
    public var work: TimeInterval = 0
    public var meeting: TimeInterval = 0
    public var uncertain: TimeInterval = 0
    public var nonWork: TimeInterval = 0
    public var breakTime: TimeInterval = 0

    public init() {}
}

public struct ClassifiedInterval: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let classification: Classification

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, classification: Classification) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.classification = classification
    }
}
