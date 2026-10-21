import SwiftUI
import UIKit

struct FeedView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter: String?
    @State private var showingAdd = false

    private var visibleItems: [ActivityItem] {
        guard let filter else { return model.items }
        return model.items.filter { $0.username == filter }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    MonitorCard()
                    content
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .refreshable {
                _ = await model.checkAll(trigger: .manual)
            }
            .navigationTitle("Logline")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .velvetScreen()
            .sheet(isPresented: $showingAdd) {
                AddAccountView()
                    .environmentObject(model)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.accounts.isEmpty {
            EmptyFeedCard { showingAdd = true }
        } else if visibleItems.isEmpty {
            Text("Nothing here yet. New diary entries, reviews and activity show up as they happen.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .padding(.top, 20)
        } else {
            ForEach(visibleItems) { item in
                Button {
                    model.open(item)
                } label: {
                    TicketView(item: item, account: model.account(item.username), hideSpoilers: model.prefs.hideSpoilers)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var filterMenu: some View {
        if model.accounts.count > 1 {
            Menu {
                Picker("Show", selection: $filter) {
                    Text("Everyone").tag(String?.none)
                    ForEach(model.accounts) { account in
                        Text(verbatim: account.displayName).tag(String?.some(account.username))
                    }
                }
            } label: {
                Image(systemName: filter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("Filter by account")
        }
    }
}

/// What Logline is doing right now, refreshed every second.
struct MonitorCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    Circle()
                        .fill(isLive ? Theme.brass : Theme.muted.opacity(0.4))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: headline)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.paper)
                        Text(verbatim: detail(now: context.date))
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    if model.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Theme.brass)
                    }
                }
            }
            permissionPrompt
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.velvetRaised))
    }

    @ViewBuilder
    private var permissionPrompt: some View {
        if model.notificationStatus == .denied {
            Button {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Label("Notifications are off for Logline. Turn them on in Settings.", systemImage: "bell.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.brass)
            }
            .buttonStyle(.plain)
        } else if model.notificationStatus == .notDetermined && !model.accounts.isEmpty {
            Button {
                Task { await model.requestNotificationPermission() }
            } label: {
                Label("Allow notifications so new activity can reach you.", systemImage: "bell.badge")
                    .font(.footnote)
                    .foregroundStyle(Theme.brass)
            }
            .buttonStyle(.plain)
        }
    }

    private var isLive: Bool {
        model.prefs.mode == .instant && model.keepAliveRunning
    }

    private var headline: String {
        switch model.accounts.count {
        case 0: return "Not watching anyone yet"
        case 1: return "Watching 1 account"
        default: return "Watching \(model.accounts.count) accounts"
        }
    }

    private func detail(now: Date) -> String {
        let mode: String
        if model.prefs.mode == .standard {
            mode = "Standard mode"
        } else if model.accounts.isEmpty {
            mode = "Instant mode starts once you add an account"
        } else {
            mode = model.keepAliveRunning ? "Instant mode" : "Instant mode isn't running"
        }
        guard let last = model.lastCheckAt else { return mode }
        return "\(mode), checked \(Format.ago(last, now: now))"
    }
}

struct EmptyFeedCard: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track someone's Letterboxd")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(Theme.paper)
            Text("Add a member and Logline alerts you when they log a film, write a review, make a list or add to their watchlist.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Button(action: onAdd) {
                Label("Add an account", systemImage: "plus")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.brass))
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 24)
    }
}
