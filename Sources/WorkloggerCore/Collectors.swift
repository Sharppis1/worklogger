import AppKit
import ApplicationServices
import Foundation
import IOKit

private final class NotificationBag: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []

    deinit {
        for token in tokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }
}

@MainActor
public protocol ObservationCollecting {
    func currentObservation() -> Observation
}

@MainActor
public final class MacSystemCollector: ObservationCollecting {
    private var isLocked = false
    private var isSleeping = false
    private let observers = NotificationBag()

    public init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        observers.tokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.isLocked = true } })
        observers.tokens.append(center.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.isLocked = false } })
        observers.tokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.isSleeping = true } })
        observers.tokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.isSleeping = false } })
    }

    public func currentObservation() -> Observation {
        if isSleeping {
            return Observation(kind: .sleep, source: "macos")
        }
        if isLocked {
            return Observation(kind: .screenLocked, source: "macos")
        }
        let idle = Self.systemIdleSeconds()
        if idle >= 60 {
            return Observation(kind: .idle, source: "macos", idleSeconds: idle)
        }
        let application = NSWorkspace.shared.frontmostApplication
        return Observation(
            kind: .activeApplication,
            source: "macos",
            application: application?.localizedName,
            bundleIdentifier: application?.bundleIdentifier,
            idleSeconds: idle
        )
    }

    public static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private static func systemIdleSeconds() -> TimeInterval {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )
        guard service != IO_OBJECT_NULL else { return 0 }
        defer { IOObjectRelease(service) }

        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return 0
        }
        return property.doubleValue / 1_000_000_000
    }

    public static func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

@MainActor
public final class DemoCollector: ObservationCollecting {
    private var index = 0
    private let observations: [Observation]

    public init(now: Date = Date()) {
        observations = [
            Observation(occurredAt: now, kind: .activeApplication, source: "demo", application: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap"),
            Observation(occurredAt: now, kind: .repositoryContext, source: "shell", repository: "digitie"),
            Observation(occurredAt: now, kind: .activeApplication, source: "demo", application: "Parallels Desktop", bundleIdentifier: "com.parallels.desktop.console"),
            Observation(occurredAt: now, kind: .idle, source: "demo", idleSeconds: 1_800),
            Observation(occurredAt: now, kind: .screenLocked, source: "demo")
        ]
    }

    public func currentObservation() -> Observation {
        defer { index = (index + 1) % observations.count }
        let template = observations[index]
        return Observation(
            kind: template.kind,
            source: template.source,
            application: template.application,
            bundleIdentifier: template.bundleIdentifier,
            host: template.host,
            repository: template.repository,
            idleSeconds: template.idleSeconds
        )
    }
}

public protocol WindowsGuestObservationProviding: Sendable {
    func latestObservation() async throws -> Observation?
}

public protocol RepositoryContextProviding: Sendable {
    func currentRepository() async throws -> String?
}
