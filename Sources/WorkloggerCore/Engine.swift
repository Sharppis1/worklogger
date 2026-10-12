import Foundation

@MainActor
public final class WorkloggerEngine: ObservableObject {
    @Published public private(set) var current = Classification(
        state: .uncertain,
        source: "startup",
        confidence: 0,
        reason: "Waiting for first observation"
    )
    @Published public private(set) var totals = DailyTotals()
    @Published public private(set) var lastError: String?
    @Published public private(set) var isDemoMode: Bool
    @Published public private(set) var privateActivities: [PrivateActivitySummary] = []

    public let config: ClassificationConfig
    private let classifier: Classifier
    private let privacy: PrivacyBoundary
    private let store: SQLiteStore
    private let syncClient: SyncClient
    private var collector: any ObservationCollecting
    private var loop: Task<Void, Never>?
    private var previousTick: Date?

    public init(
        config: ClassificationConfig,
        store: SQLiteStore,
        endpoint: URL,
        demoMode: Bool
    ) {
        self.config = config
        classifier = Classifier(config: config)
        privacy = PrivacyBoundary(classifier: classifier)
        self.store = store
        syncClient = SyncClient(baseURL: endpoint, store: store, privacy: privacy)
        isDemoMode = demoMode
        collector = demoMode
            ? DemoCollector()
            : MacSystemCollector(browserTargetRules: config.browserTargets)
    }

    deinit {
        loop?.cancel()
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    public func setDemoMode(_ enabled: Bool) {
        isDemoMode = enabled
        collector = enabled
            ? DemoCollector()
            : MacSystemCollector(browserTargetRules: config.browserTargets)
        previousTick = nil
    }

    public func markCurrentAsWork(topic: String? = nil, minutes: Int = 60) {
        addCorrection(kind: .markWork, duration: minutes, topic: topic)
    }

    public func markPreviousIntervalAsWork(minutes: Int = 15, topic: String? = nil) {
        let correction = ManualCorrection(
            effectiveFrom: Date().addingTimeInterval(-TimeInterval(minutes * 60)),
            effectiveUntil: Date(),
            kind: .previousIntervalWork,
            topic: topic
        )
        persist(correction)
    }

    public func selectTopic(_ topic: String, minutes: Int = 60) {
        addCorrection(kind: .topic, duration: minutes, topic: topic)
    }

    public func startBreak(minutes: Int) {
        addCorrection(kind: .breakTime, duration: minutes)
    }

    public func startPaperPlanning(minutes: Int) {
        addCorrection(kind: .paperPlanning, duration: minutes, topic: "Paper planning")
    }

    public func pause(minutes: Int) {
        addCorrection(kind: .pause, duration: minutes)
    }

    public func resume() {
        Task {
            do {
                let now = Date()
                let active = try await store.activeCorrection(at: now)
                let correction = ManualCorrection(
                    effectiveFrom: now,
                    effectiveUntil: active?.effectiveUntil ?? now.addingTimeInterval(1),
                    kind: .resume
                )
                try await store.save(correction)
                await tick()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func refreshPrivateActivities() {
        Task {
            do {
                try await loadPrivateActivities(now: Date())
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    public func classifyAsWork(_ summary: PrivateActivitySummary, topic: String) {
        let normalizedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTopic.isEmpty else { return }
        Task {
            do {
                let now = Date()
                try await store.save(UserClassificationRule(
                    kind: summary.kind,
                    matchValue: summary.matchValue,
                    topic: normalizedTopic,
                    createdAt: now
                ))
                for interval in summary.intervals {
                    try await store.save(ManualCorrection(
                        createdAt: now,
                        effectiveFrom: interval.start,
                        effectiveUntil: interval.end,
                        kind: .previousIntervalWork,
                        topic: normalizedTopic
                    ))
                }
                try await loadPrivateActivities(now: now)
                do {
                    try await syncClient.syncPending()
                } catch {
                    // Corrections remain buffered until the loopback service returns.
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func addCorrection(kind: OverrideKind, duration minutes: Int, topic: String? = nil) {
        let now = Date()
        persist(ManualCorrection(
            effectiveFrom: now,
            effectiveUntil: now.addingTimeInterval(TimeInterval(minutes * 60)),
            kind: kind,
            topic: topic
        ))
    }

    private func persist(_ correction: ManualCorrection) {
        Task {
            do {
                try await store.save(correction)
                await tick()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func tick() async {
        let now = Date()
        let observation = collector.currentObservation()
        do {
            let activeCorrection = try await store.activeCorrection(at: now)
            let userRules = try await store.userRules()
            let next = classifier.classify(
                observation: observation,
                activeCorrection: activeCorrection,
                userRules: userRules
            )
            let privacyLevel = privacy.localPrivacy(for: observation, userRules: userRules)
            try await store.save(observation, privacy: privacyLevel)

            if let start = previousTick, now > start {
                try await store.save(ClassifiedInterval(
                    startedAt: start,
                    endedAt: now,
                    classification: current
                ))
            }
            previousTick = now
            current = next
            totals = try await store.totals(for: now)
            try await store.purgeExpiredPrivateDetails(now: now)
            try await loadPrivateActivities(now: now, userRules: userRules)
            lastError = nil
            do {
                try await syncClient.syncPending()
            } catch {
                // Local collection remains authoritative while the loopback service is unavailable.
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadPrivateActivities(
        now: Date,
        userRules: [UserClassificationRule]? = nil
    ) async throws {
        let rules: [UserClassificationRule]
        if let userRules {
            rules = userRules
        } else {
            rules = try await store.userRules()
        }
        privateActivities = try await store.privateActivitySummaries(
            since: now.addingTimeInterval(-TimeInterval(config.privateRetentionHours * 3_600)),
            now: now,
            classifier: classifier,
            userRules: rules
        )
    }
}
