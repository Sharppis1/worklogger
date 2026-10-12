import ServiceManagement
import SwiftUI
import WorkloggerCore

@main
struct WorkloggerMenuBarApp: App {
    @StateObject private var engine: WorkloggerEngine

    init() {
        do {
            let config = try ClassificationConfig.bundled()
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "Worklogger", directoryHint: .isDirectory)
            let store = try SQLiteStore(
                url: support.appending(path: "worklogger.sqlite3"),
                privateRetentionHours: config.privateRetentionHours
            )
            let demo = ProcessInfo.processInfo.arguments.contains("--demo")
                || ProcessInfo.processInfo.environment["WORKLOGGER_DEMO"] == "1"
            let appEngine = WorkloggerEngine(
                config: config,
                store: store,
                endpoint: URL(string: "http://127.0.0.1:8787")!,
                demoMode: demo
            )
            appEngine.start()
            _engine = StateObject(wrappedValue: appEngine)
        } catch {
            fatalError("Worklogger cannot initialize: \(error)")
        }
    }

    var body: some Scene {
        MenuBarExtra {
            WorkloggerMenu(engine: engine)
        } label: {
            Label(engine.current.state.label, systemImage: engine.current.state.symbol)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct WorkloggerMenu: View {
    @ObservedObject var engine: WorkloggerEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: engine.current.state.symbol)
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(engine.current.state.label).font(.headline)
                    Text(contextLine).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            Text("Today").font(.headline)
            HStack {
                total("Work", engine.totals.work)
                total("Meetings", engine.totals.meeting)
                total("Uncertain", engine.totals.uncertain)
            }

            Divider()
            HStack {
                Button("Mark work") { engine.markCurrentAsWork() }
                Button("Previous 15 min") { engine.markPreviousIntervalAsWork() }
            }

            Menu("Select topic") {
                ForEach(engine.config.workRepositories, id: \.self) { topic in
                    Button(topic) { engine.selectTopic(topic) }
                }
            }

            HStack {
                Menu("Break") {
                    Button("15 minutes") { engine.startBreak(minutes: 15) }
                    Button("30 minutes") { engine.startBreak(minutes: 30) }
                    Button("60 minutes") { engine.startBreak(minutes: 60) }
                }
                Menu("Paper planning") {
                    Button("15 minutes") { engine.startPaperPlanning(minutes: 15) }
                    Button("30 minutes") { engine.startPaperPlanning(minutes: 30) }
                    Button("60 minutes") { engine.startPaperPlanning(minutes: 60) }
                }
            }

            HStack {
                Menu("Pause tracking") {
                    Button("15 minutes") { engine.pause(minutes: 15) }
                    Button("1 hour") { engine.pause(minutes: 60) }
                    Button("4 hours") { engine.pause(minutes: 240) }
                }
                Button("Resume") { engine.resume() }
            }

            Button(engine.isDemoMode ? "Disable simulation mode" : "Enable simulation mode") {
                engine.setDemoMode(!engine.isDemoMode)
            }
            Button(launchAtLogin ? "Disable launch at login" : "Enable launch at login") {
                updateLaunchAtLogin(!launchAtLogin)
            }

            if !MacSystemCollector.accessibilityGranted {
                Button("Allow optional Accessibility access") {
                    MacSystemCollector.requestAccessibilityPermission()
                }
                Text("Needed only by future browser/repository context integrations; basic app and idle tracking work without it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 380)
    }

    private var contextLine: String {
        [engine.current.topic, engine.current.source]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func total(_ label: String, _ seconds: TimeInterval) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(duration(seconds)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
