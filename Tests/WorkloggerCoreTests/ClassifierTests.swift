import XCTest
@testable import WorkloggerCore

final class ClassifierTests: XCTestCase {
    private var config: ClassificationConfig!
    private var classifier: Classifier!

    override func setUpWithError() throws {
        config = try ClassificationConfig.bundled()
        classifier = Classifier(config: config)
    }

    func testExactHostRulesDoNotUseUnsafeSubstringMatching() {
        let accepted = classifier.classify(observation: Observation(
            kind: .browserHost,
            source: "test",
            host: "teams.ansfinland.fi"
        ))
        let rejected = classifier.classify(observation: Observation(
            kind: .browserHost,
            source: "test",
            host: "ansfinland.fi.attacker.example"
        ))
        let extraSubdomain = classifier.classify(observation: Observation(
            kind: .browserHost,
            source: "test",
            host: "other.extra.tie.fintraffic.fi"
        ))

        XCTAssertEqual(accepted.state, .work)
        XCTAssertEqual(rejected.state, .nonWork)
        XCTAssertEqual(extraSubdomain.state, .nonWork)
    }

    func testAnsFinlandSharePointIsWorkWithoutMatchingOtherTenants() {
        let intranet = classifier.classify(observation: Observation(
            kind: .browserHost,
            source: "macos",
            host: "ansfinland.sharepoint.com"
        ))
        let otherTenant = classifier.classify(observation: Observation(
            kind: .browserHost,
            source: "macos",
            host: "other.sharepoint.com"
        ))

        XCTAssertEqual(intranet.state, .work)
        XCTAssertEqual(intranet.topic, "ansfinland.sharepoint.com")
        XCTAssertEqual(otherTenant.state, .nonWork)
    }

    func testLongIdleIsUncertainAndLockedIsNonWork() {
        XCTAssertEqual(classifier.classify(observation: Observation(
            kind: .idle,
            source: "test",
            idleSeconds: 3_600
        )).state, .uncertain)
        XCTAssertEqual(classifier.classify(observation: Observation(
            kind: .screenLocked,
            source: "test"
        )).state, .nonWork)
    }

    func testTerminalRequiresRepositoryContext() {
        let terminal = classifier.classify(observation: Observation(
            kind: .activeApplication,
            source: "test",
            application: "Terminal",
            bundleIdentifier: "com.apple.Terminal"
        ))
        let repository = classifier.classify(observation: Observation(
            kind: .repositoryContext,
            source: "shell",
            repository: "digitie"
        ))

        XCTAssertEqual(terminal.state, .uncertain)
        XCTAssertEqual(repository.state, .work)
    }

    func testMicrosoftWordBundleIsWork() {
        let result = classifier.classify(observation: Observation(
            kind: .activeApplication,
            source: "macos",
            application: "Microsoft Word",
            bundleIdentifier: "com.microsoft.Word"
        ))

        XCTAssertEqual(result.state, .work)
        XCTAssertEqual(result.topic, "Microsoft Word")
    }

    func testWindowsGuestSupersedesGenericParallels() {
        let host = Observation(
            kind: .activeApplication,
            source: "macos",
            application: "Parallels Desktop",
            bundleIdentifier: "com.parallels.desktop.console"
        )
        let guest = Observation(
            kind: .windowsGuest,
            source: "windows_guest",
            application: "Microsoft Word"
        )

        XCTAssertEqual(classifier.classify(observation: host).state, .uncertain)
        XCTAssertEqual(classifier.classify(observation: host, windowsGuestObservation: guest).state, .work)
    }

    func testCalendarIsIntentNotMeetingProof() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 8))!
        let event = CalendarEvent(
            id: "focus",
            titleCategory: nil,
            startsAt: start,
            endsAt: start.addingTimeInterval(45 * 60),
            isBlocking: true
        )
        let result = classifier.classify(observation: Observation(
            kind: .calendarIntent,
            source: "calendar",
            calendar: event
        ))

        XCTAssertEqual(result.state, .uncertain)
        XCTAssertTrue(result.reason.contains("not meeting"))
    }

    func testManualOverrideWinsAndExpires() {
        let now = Date()
        let correction = ManualCorrection(
            effectiveFrom: now.addingTimeInterval(-10),
            effectiveUntil: now.addingTimeInterval(10),
            kind: .breakTime
        )
        let observation = Observation(
            occurredAt: now,
            kind: .activeApplication,
            source: "test",
            application: "Slack"
        )
        XCTAssertEqual(classifier.classify(observation: observation, activeCorrection: correction).state, .breakTime)
    }
}
