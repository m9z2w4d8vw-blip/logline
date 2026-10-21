import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                if model.accounts.isEmpty {
                    Section {
                        Text("Add a Letterboxd member to start getting alerts when they log, review, list or like something.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                        Button {
                            showingAdd = true
                        } label: {
                            Label("Add an account", systemImage: "plus")
                        }
                    }
                    .listRowBackground(Theme.velvetRaised)
                } else {
                    Section {
                        ForEach(model.accounts) { account in
                            NavigationLink(value: account.username) {
                                AccountRow(account: account)
                            }
                        }
                        .onDelete { offsets in
                            model.removeAccounts(at: offsets)
                        }
                    } footer: {
                        Text("Swipe left on an account to stop tracking it.")
                    }
                    .listRowBackground(Theme.velvetRaised)
                }
            }
            .navigationTitle("Accounts")
            .navigationDestination(for: String.self) { username in
                AccountDetailView(username: username)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add account")
                }
            }
            .velvetScreen()
            .sheet(isPresented: $showingAdd) {
                AddAccountView()
                    .environmentObject(model)
            }
        }
    }
}

struct AccountRow: View {
    let account: TrackedAccount

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(urlString: account.avatarURL, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: account.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.paper)
                Text(verbatim: "@" + account.username)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                if let error = account.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.brass)
                        .lineLimit(2)
                } else if let stats = account.stats, !stats.summary.isEmpty {
                    Text(verbatim: stats.summary)
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            if !account.notificationsEnabled {
                Image(systemName: "bell.slash")
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 4)
    }
}

struct AccountDetailView: View {
    let username: String

    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    var body: some View {
        Group {
            if let account = model.account(username) {
                List {
                    Section {
                        ProfileHeader(account: account)
                    }
                    .listRowBackground(Color.clear)

                    Section {
                        Toggle("Alerts for this account", isOn: alertsBinding)
                        ForEach(NotificationTopic.allCases) { topic in
                            Toggle(topic.label, isOn: topicBinding(topic))
                                .disabled(!account.notificationsEnabled)
                        }
                    } header: {
                        Text("Notify me about")
                    } footer: {
                        Text("Watchlist additions, likes and follows come from the profile page, so they need Watch profile activity turned on in Settings.")
                    }
                    .listRowBackground(Theme.velvetRaised)

                    Section {
                        LabeledContent("Last checked", value: Format.ago(account.lastChecked))
                        LabeledContent("RSS feed", value: account.lastError ?? "Working")
                        LabeledContent("Profile activity", value: profileStatus(account))
                        if let note = account.profileNote {
                            Text(verbatim: note)
                                .font(.footnote)
                                .foregroundStyle(Theme.brass)
                        }
                    } header: {
                        Text("Status")
                    }
                    .listRowBackground(Theme.velvetRaised)

                    recentSection

                    Section {
                        if let url = account.profileURL {
                            Button {
                                openURL(url)
                            } label: {
                                Label("Open profile in Letterboxd", systemImage: "arrow.up.right.square")
                            }
                        }
                        Button(role: .destructive) {
                            confirmingRemoval = true
                        } label: {
                            Label("Stop tracking", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Theme.velvetRaised)
                }
                .navigationTitle(account.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .confirmationDialog("Stop tracking \(account.displayName)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                    Button("Stop tracking", role: .destructive) {
                        model.removeAccount(username)
                        dismiss()
                    }
                }
            } else {
                Text("This account is no longer tracked.")
                    .foregroundStyle(Theme.muted)
            }
        }
        .velvetScreen()
    }

    @ViewBuilder
    private var recentSection: some View {
        let recent = Array(model.items(for: username).prefix(15))
        if !recent.isEmpty {
            Section {
                ForEach(recent) { item in
                    Button {
                        model.open(item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.kind.symbol)
                                .foregroundStyle(Theme.brass)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.title)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.paper)
                                    .lineLimit(1)
                                Text(verbatim: item.metaLine)
                                    .font(.caption)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(verbatim: Format.short(item.date))
                                .font(.caption2)
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
            } header: {
                Text("Recent")
            }
            .listRowBackground(Theme.velvetRaised)
        }
    }

    private var alertsBinding: Binding<Bool> {
        Binding(
            get: { model.account(username)?.notificationsEnabled ?? true },
            set: { value in
                model.updateAccount(username) { $0.notificationsEnabled = value }
            }
        )
    }

    private func topicBinding(_ topic: NotificationTopic) -> Binding<Bool> {
        Binding(
            get: {
                guard let current = model.account(username) else { return true }
                return !topic.kinds.allSatisfy { current.mutedKinds.contains($0) }
            },
            set: { enabled in
                model.updateAccount(username) { tracked in
                    tracked.mutedKinds.removeAll { topic.kinds.contains($0) }
                    if !enabled {
                        tracked.mutedKinds.append(contentsOf: topic.kinds)
                    }
                }
            }
        )
    }

    private func profileStatus(_ account: TrackedAccount) -> String {
        guard model.prefs.watchProfiles else { return "Off in Settings" }
        switch account.profileMode {
        case .timeline: return "Reading the activity sidebar"
        case .watchlistOnly: return "Watchlist preview only"
        case .unknown: return "Not read yet"
        }
    }
}

struct ProfileHeader: View {
    let account: TrackedAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                AvatarView(urlString: account.avatarURL, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: account.displayName)
                        .font(.system(.title2, design: .serif).weight(.semibold))
                        .foregroundStyle(Theme.paper)
                    Text(verbatim: "@" + account.username)
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
            }
            if let stats = account.stats {
                HStack(spacing: 18) {
                    StatView(value: stats.films, label: "Films")
                    StatView(value: stats.thisYear, label: "This year")
                    StatView(value: stats.following, label: "Following")
                    StatView(value: stats.followers, label: "Followers")
                }
            }
        }
        .padding(.vertical, 6)
    }
}

struct StatView: View {
    let value: Int?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: value.map { String($0) } ?? "–")
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.paper)
            Text(verbatim: label)
                .font(.caption2)
                .foregroundStyle(Theme.muted)
        }
    }
}

struct AddAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var isWorking = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var trimmed: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username or profile link", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(add)
                } footer: {
                    Text("Paste letterboxd.com/username or type the username. Logline reads the member's public RSS feed and profile page, so no login is needed.")
                }
                .listRowBackground(Theme.velvetRaised)

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.brass)
                    }
                    .listRowBackground(Theme.velvetRaised)
                }
            }
            .navigationTitle("Track an account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Track", action: add)
                            .disabled(trimmed.isEmpty)
                    }
                }
            }
            .velvetScreen()
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard !isWorking, !trimmed.isEmpty else { return }
        isWorking = true
        errorText = nil
        let value = trimmed
        Task { @MainActor in
            do {
                try await model.addAccount(value)
                isWorking = false
                dismiss()
            } catch {
                isWorking = false
                errorText = error.localizedDescription
            }
        }
    }
}
