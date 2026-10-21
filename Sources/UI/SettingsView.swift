import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                monitoringSection
                notificationSection
                sourcesSection
                backgroundSection
                updatesSection
                diagnosticsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .velvetScreen()
        }
    }

    private var monitoringSection: some View {
        Section {
            Picker("Mode", selection: $model.prefs.mode) {
                ForEach(MonitoringMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Picker("Check every", selection: $model.prefs.pollInterval) {
                ForEach(Preferences.intervals, id: \.self) { seconds in
                    Text(Format.interval(seconds)).tag(seconds)
                }
            }
            if model.prefs.mode == .instant {
                Toggle("Warn me if watching stops", isOn: $model.prefs.watchdog)
                LabeledContent("Keep-alive", value: model.keepAliveRunning ? "Running" : "Not running")
            }
        } header: {
            Text("Monitoring")
        } footer: {
            Text(model.prefs.mode == .instant ? Copy.instant : Copy.standard)
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var notificationSection: some View {
        Section {
            LabeledContent("Permission", value: permissionLabel)
            if model.notificationStatus == .notDetermined {
                Button("Allow notifications") {
                    Task { await model.requestNotificationPermission() }
                }
            } else if model.notificationStatus == .denied {
                Button("Open notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            Toggle("Attach posters", isOn: $model.prefs.attachImages)
            Toggle("Hide spoiler reviews", isOn: $model.prefs.hideSpoilers)
            if model.timeSensitiveSupported {
                Toggle("Time Sensitive", isOn: $model.prefs.timeSensitive)
            }
            Button("Send a test notification") {
                Task { await model.sendTestNotification() }
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text(model.timeSensitiveSupported ? Copy.timeSensitive : Copy.noTimeSensitive)
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var sourcesSection: some View {
        Section {
            Toggle("Watch profile activity", isOn: $model.prefs.watchProfiles)
            Toggle("Skip Letterboxd's cache", isOn: $model.prefs.bypassCache)
        } header: {
            Text("What Logline reads")
        } footer: {
            Text(Copy.sources)
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var backgroundSection: some View {
        Section {
            LabeledContent("Background App Refresh", value: refreshLabel)
            if model.backgroundRuns.isEmpty {
                Text("iOS hasn't given Logline a background run yet.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            } else {
                ForEach(model.backgroundRuns.prefix(6)) { run in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: run.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                            Text(verbatim: run.trigger)
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text(verbatim: run.ok ? (run.newItems == 1 ? "1 new" : "\(run.newItems) new") : "Failed")
                            .font(.footnote)
                            .foregroundStyle(run.ok ? Theme.muted : Theme.brass)
                    }
                }
            }
        } header: {
            Text("Background")
        } footer: {
            Text(Copy.background)
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var updatesSection: some View {
        Section {
            LabeledContent("Installed", value: "Build \(AppInfo.build)")
            if let update = model.availableUpdate {
                if let ipa = update.ipaURL, let install = Updater.trollStoreURL(for: ipa) {
                    Button {
                        openURL(install)
                    } label: {
                        Label("Install build \(update.build) with TrollStore", systemImage: "arrow.down.circle")
                    }
                }
                Button {
                    openURL(update.pageURL)
                } label: {
                    Label("Open the release page", systemImage: "safari")
                }
            }
            Button {
                Task { await model.checkForUpdate() }
            } label: {
                HStack {
                    Text("Check for updates")
                    Spacer()
                    if model.isCheckingForUpdate {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isCheckingForUpdate)
            if let message = model.updateMessage {
                Text(verbatim: message)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(Copy.updates)
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var diagnosticsSection: some View {
        Section {
            Button {
                Task { _ = await model.checkAll(trigger: .manual) }
            } label: {
                HStack {
                    Text("Check now")
                    Spacer()
                    if model.isChecking {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isChecking || model.accounts.isEmpty)
            NavigationLink("Activity log") {
                LogView()
            }
        } header: {
            Text("Diagnostics")
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var aboutSection: some View {
        Section {
            Text(Copy.about)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .listRowBackground(Theme.velvetRaised)
    }

    private var permissionLabel: String {
        switch model.notificationStatus {
        case .authorized: return "Allowed"
        case .denied: return "Off"
        case .notDetermined: return "Not asked yet"
        case .provisional: return "Delivered quietly"
        case .ephemeral: return "Temporary"
        @unknown default: return "Unknown"
        }
    }

    private var refreshLabel: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "On"
        case .denied: return "Off"
        case .restricted: return "Restricted"
        @unknown default: return "Unknown"
        }
    }
}

struct LogView: View {
    @State private var entries: [Log.Entry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("Nothing logged yet.")
                    .foregroundStyle(Theme.muted)
                    .listRowBackground(Theme.velvetRaised)
            }
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: entry.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                    Text(verbatim: entry.message)
                        .font(.footnote.monospaced())
                        .foregroundStyle(color(for: entry.level))
                        .textSelection(.enabled)
                }
                .listRowBackground(Theme.velvetRaised)
            }
        }
        .navigationTitle("Activity log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: Log.shared.exportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .refreshable {
            entries = Log.shared.snapshot()
        }
        .onAppear {
            entries = Log.shared.snapshot()
        }
        .velvetScreen()
    }

    private func color(for level: Log.Level) -> Color {
        switch level {
        case .info: return Theme.paper
        case .warning: return Theme.brass
        case .error: return Color(red: 0.95, green: 0.5, blue: 0.45)
        }
    }
}

enum Copy {
    static let instant = "Logline keeps itself awake in the background with a silent audio session that never interrupts your music, and checks on the schedule above. Alerts land within one interval of a post. It costs some battery, and swiping Logline away in the app switcher stops it."
    static let standard = "Logline checks whenever it's open. In the background, iOS decides when it runs: often every 15 minutes to a few hours, more often the more you use the app."
    static let timeSensitive = "Time Sensitive alerts get through Focus modes and the scheduled summary."
    static let noTimeSensitive = "Time Sensitive alerts need the entitlement the GitHub build signs in, which TrollStore keeps when it installs."
    static let sources = "Diary entries, reviews and lists always come from each member's public RSS feed. Profile activity reads their public profile page for watchlist additions, likes and follows. Skipping the cache adds a throwaway parameter to each request so a cached copy can't hold back a new post."
    static let background = "Every background run iOS grants Logline is listed here, so you can see how often it really happens on your phone."
    static let updates = "Builds come from this repo's GitHub releases. One-tap installs need TrollStore's URL scheme turned on in TrollStore's settings."
    static let about = "Logline is a personal tool and isn't affiliated with Letterboxd. It reads the same public RSS feeds and profile pages anyone can open in a browser."
}
