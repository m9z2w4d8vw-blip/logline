import SwiftUI

struct ActivityDetailView: View {
    let item: ActivityItem

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var revealSpoilers = false

    private var account: TrackedAccount? {
        model.account(item.username)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heading
                    reviewText
                    listFilms
                    timing
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let link = item.link, let url = URL(string: link) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Letterboxd", systemImage: "arrow.up.right.square")
                        }
                    }
                }
            }
            .velvetScreen()
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 16) {
            PosterView(urlString: item.imageURL, kind: item.kind)
                .frame(width: 112, height: 168)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: account?.displayName ?? item.username)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.brass)
                Text(verbatim: item.title)
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .foregroundStyle(Theme.paper)
                if let year = item.filmYear {
                    Text(verbatim: year)
                        .font(.system(.callout, design: .serif))
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 8) {
                    if let stars = item.stars {
                        Text(verbatim: stars)
                            .foregroundStyle(Theme.brass)
                    }
                    if item.liked && item.kind.isDiary {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(Theme.stamp)
                    }
                    if item.rewatch {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(Theme.muted)
                    }
                }
                .font(.callout)
                Text(verbatim: item.metaLine)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private var reviewText: some View {
        if let text = item.text, !text.isEmpty {
            if item.spoilers && model.prefs.hideSpoilers && !revealSpoilers {
                Button {
                    revealSpoilers = true
                } label: {
                    Label("This review may contain spoilers. Show it.", systemImage: "eye")
                        .font(.callout)
                        .foregroundStyle(Theme.brass)
                }
                .buttonStyle(.plain)
            } else {
                Text(verbatim: text)
                    .font(.system(.body, design: .serif))
                    .lineSpacing(5)
                    .foregroundStyle(Theme.paper)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var listFilms: some View {
        if !item.listFilms.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(item.listFilms.enumerated()), id: \.offset) { pair in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if item.listRanked {
                            Text(verbatim: "\(pair.offset + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.muted)
                                .frame(width: 22, alignment: .trailing)
                        }
                        Text(verbatim: pair.element)
                            .font(.system(.body, design: .serif))
                            .foregroundStyle(Theme.paper)
                    }
                }
                if let count = item.listCount, count > item.listFilms.count {
                    Text(verbatim: "and \(count - item.listFilms.count) more on Letterboxd")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private var timing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "Posted " + item.date.formatted(date: .abbreviated, time: .shortened))
            if item.live {
                Text(verbatim: "Logline noticed it \(Format.latency(item.detectedAt.timeIntervalSince(item.date))) later")
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
    }
}
