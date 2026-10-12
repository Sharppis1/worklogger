import XCTest
@testable import WorkloggerCore

final class PersistenceTests: XCTestCase {
    func testIntervalsAreSplitAtReportDayBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = try SQLiteStore(
            url: directory.appending(path: "test.sqlite3"),
            privateRetentionHours: 24
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        let work = Classification(state: .work, source: "test", confidence: 1, reason: "test")
        try await store.save(ClassifiedInterval(
            startedAt: midnight.addingTimeInterval(-30 * 60),
            endedAt: midnight.addingTimeInterval(30 * 60),
            classification: work
        ))

        let totals = try await store.totals(for: midnight, calendar: calendar)
        XCTAssertEqual(totals.work, 30 * 60, accuracy: 0.1)
    }

    func testNonWorkIsSanitizedToGenericPrivateActivity() throws {
        let classifier = Classifier(config: try ClassificationConfig.bundled())
        let privacy = PrivacyBoundary(classifier: classifier)
        let envelope = privacy.sanitize(Observation(
            kind: .activeApplication,
            source: "macos",
            application: "Personal Secret App",
            bundleIdentifier: "example.private"
        ))

        XCTAssertEqual(envelope.activity, "private_activity")
        XCTAssertNil(envelope.workTopic)
    }

    func testResumeNeutralizesEarlierActiveOverride() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = try SQLiteStore(
            url: directory.appending(path: "test.sqlite3"),
            privateRetentionHours: 24
        )
        let now = Date()
        let end = now.addingTimeInterval(3_600)
        try await store.save(ManualCorrection(
            createdAt: now.addingTimeInterval(-60),
            effectiveFrom: now.addingTimeInterval(-60),
            effectiveUntil: end,
            kind: .topic,
            topic: "digitie"
        ))
        try await store.save(ManualCorrection(
            createdAt: now,
            effectiveFrom: now,
            effectiveUntil: end,
            kind: .resume
        ))

        let active = try await store.activeCorrection(at: now.addingTimeInterval(1))
        XCTAssertNil(active)
    }
}
