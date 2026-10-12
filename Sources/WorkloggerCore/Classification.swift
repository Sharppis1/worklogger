import Foundation

public struct HostRule: Codable, Equatable, Sendable {
    public let host: String
    public let includeSubdomains: Bool

    public init(host: String, includeSubdomains: Bool) {
        self.host = host.lowercased()
        self.includeSubdomains = includeSubdomains
    }

    public func matches(_ candidate: String) -> Bool {
        let normalized = candidate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == host || (includeSubdomains && normalized.hasSuffix("." + host))
    }
}

public struct BrowserTargetRule: Codable, Equatable, Sendable {
    public let host: String
    public let pathPrefix: String
    public let topic: String

    public init(host: String, pathPrefix: String, topic: String) {
        self.host = host.lowercased()
        self.pathPrefix = pathPrefix.hasPrefix("/") ? pathPrefix : "/" + pathPrefix
        self.topic = topic
    }

    public func matches(_ url: URL) -> Bool {
        guard url.host?.lowercased() == host else { return false }
        let path = url.path
        return path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }

    public func matches(host candidateHost: String, topic candidateTopic: String) -> Bool {
        candidateHost.caseInsensitiveCompare(host) == .orderedSame
            && candidateTopic == topic
    }
}

public struct ClassificationConfig: Codable, Equatable, Sendable {
    public var workApplications: [String]
    public var workBundleIdentifiers: [String]
    public var browserBundleIdentifiers: [String]
    public var terminalBundleIdentifiers: [String]
    public var workRepositories: [String]
    public var workHosts: [HostRule]
    public var browserTargets: [BrowserTargetRule]
    public var parallelsBundleIdentifiers: [String]
    public var idleUncertainAfterSeconds: TimeInterval
    public var privateRetentionHours: Int

    public static func bundled() throws -> ClassificationConfig {
        guard let url = Bundle.module.url(forResource: "default-classification", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(ClassificationConfig.self, from: Data(contentsOf: url))
    }
}

public struct Classifier: Sendable {
    public let config: ClassificationConfig

    public init(config: ClassificationConfig) {
        self.config = config
    }

    public func classify(
        observation: Observation,
        activeCorrection: ManualCorrection? = nil,
        windowsGuestObservation: Observation? = nil,
        userRules: [UserClassificationRule] = []
    ) -> Classification {
        if let correction = activeCorrection, correction.isActive(at: observation.occurredAt) {
            return classify(correction)
        }
        if let rule = userRules.first(where: { $0.matches(observation) }) {
            return Classification(
                state: .work,
                topic: rule.topic,
                source: observation.source,
                confidence: 1,
                reason: "Local user rule"
            )
        }

        switch observation.kind {
        case .screenLocked, .sleep:
            return Classification(state: .nonWork, source: observation.source, confidence: 1, reason: "Device unavailable")
        case .idle where (observation.idleSeconds ?? 0) >= config.idleUncertainAfterSeconds:
            return Classification(state: .uncertain, source: observation.source, confidence: 0.4, reason: "Long inactivity is not proof of non-work")
        case .browserHost:
            if let host = observation.host,
               let target = observation.browserTarget,
               config.browserTargets.contains(where: { $0.matches(host: host, topic: target) }) {
                return Classification(state: .work, topic: target, source: observation.source, confidence: 0.95, reason: "Configured browser target")
            }
            if let host = observation.host, config.workHosts.contains(where: { $0.matches(host) }) {
                return Classification(state: .work, topic: host, source: observation.source, confidence: 0.9, reason: "Configured exact host rule")
            }
            return Classification(state: .nonWork, source: observation.source, confidence: 0.6, reason: "Unrecognized browser target")
        case .repositoryContext:
            if let repository = observation.repository, config.workRepositories.contains(where: { $0.caseInsensitiveCompare(repository) == .orderedSame }) {
                return Classification(state: .work, topic: repository, source: observation.source, confidence: 0.95, reason: "Configured repository")
            }
            return Classification(state: .uncertain, source: observation.source, confidence: 0.4, reason: "Unrecognized repository")
        case .windowsGuest:
            return classifyWindowsGuest(observation)
        case .calendarIntent:
            return classifyCalendar(observation.calendar, source: observation.source)
        case .activeApplication:
            return classifyApplication(observation, windowsGuestObservation: windowsGuestObservation)
        case .manual:
            return Classification(state: .uncertain, source: observation.source, confidence: 0.2, reason: "Manual event without active correction")
        case .screenUnlocked, .wake, .idle:
            return Classification(state: .uncertain, source: observation.source, confidence: 0.3, reason: "Insufficient evidence")
        }
    }

    private func classify(_ correction: ManualCorrection) -> Classification {
        switch correction.kind {
        case .markWork, .previousIntervalWork:
            Classification(state: .work, topic: correction.topic, source: "manual", confidence: 1, reason: "Manual correction")
        case .topic:
            Classification(state: .work, topic: correction.topic, source: "manual", confidence: 1, reason: "Manual topic")
        case .breakTime:
            Classification(state: .breakTime, source: "manual", confidence: 1, reason: "Manual break")
        case .paperPlanning:
            Classification(state: .work, topic: correction.topic ?? "Paper planning", source: "manual", confidence: 1, reason: "Bounded paper planning")
        case .pause:
            Classification(state: .paused, source: "manual", confidence: 1, reason: "Tracking paused")
        case .resume:
            Classification(state: .uncertain, source: "manual", confidence: 0.2, reason: "Tracking resumed")
        }
    }

    private func classifyApplication(_ observation: Observation, windowsGuestObservation: Observation?) -> Classification {
        let bundle = observation.bundleIdentifier ?? ""
        if config.parallelsBundleIdentifiers.contains(bundle) {
            if let guest = windowsGuestObservation {
                return classifyWindowsGuest(guest)
            }
            return Classification(state: .uncertain, source: observation.source, confidence: 0.5, reason: "Parallels requires Windows guest detail")
        }
        if config.terminalBundleIdentifiers.contains(bundle) {
            return Classification(state: .uncertain, source: observation.source, confidence: 0.5, reason: "Terminal requires configured repository context")
        }
        if config.browserBundleIdentifiers.contains(bundle) {
            return Classification(state: .uncertain, source: observation.source, confidence: 0.4, reason: "Browser requires host context")
        }
        if config.workBundleIdentifiers.contains(bundle)
            || config.workApplications.contains(where: { $0.caseInsensitiveCompare(observation.application ?? "") == .orderedSame }) {
            return Classification(state: .work, topic: observation.application, source: observation.source, confidence: 0.85, reason: "Configured work application")
        }
        return Classification(state: .nonWork, source: observation.source, confidence: 0.6, reason: "Unrecognized application")
    }

    private func classifyWindowsGuest(_ observation: Observation) -> Classification {
        guard let application = observation.application else {
            return Classification(state: .uncertain, source: "windows_guest", confidence: 0.4, reason: "Guest detail missing")
        }
        if config.workApplications.contains(where: { $0.caseInsensitiveCompare(application) == .orderedSame }) {
            return Classification(state: .work, topic: application, source: "windows_guest", confidence: 0.9, reason: "Windows guest supersedes Parallels host")
        }
        return Classification(state: .nonWork, source: "windows_guest", confidence: 0.7, reason: "Windows guest application")
    }

    private func classifyCalendar(_ event: CalendarEvent?, source: String) -> Classification {
        guard let event else {
            return Classification(state: .uncertain, source: source, confidence: 0.2, reason: "Calendar context missing")
        }
        if event.titleCategory?.uppercased() == "LOUNAS" {
            return Classification(state: .breakTime, source: source, confidence: 0.7, reason: "Calendar break intent")
        }
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.dateComponents([.hour, .minute], from: event.startsAt)
        let end = calendar.dateComponents([.hour, .minute], from: event.endsAt)
        if event.isBlocking, start.hour == 8, start.minute == 0, end.hour == 8, end.minute == 45 {
            return Classification(state: .uncertain, source: source, confidence: 0.5, reason: "Focus/reservation block, not meeting proof")
        }
        return Classification(state: .uncertain, source: source, confidence: 0.4, reason: "Calendar is intent only")
    }
}
