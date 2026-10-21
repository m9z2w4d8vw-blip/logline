import SwiftUI

/// One piece of activity, printed as a ticket: poster on the stub, details past the perforation.
struct TicketView: View {
    let item: ActivityItem
    let account: TrackedAccount?
    let hideSpoilers: Bool

    private let stubWidth: CGFloat = 70
    private let inset: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            PosterView(urlString: item.imageURL, kind: item.kind)
                .frame(width: stubWidth, height: stubWidth * 1.5)
                .padding(inset)
            VStack(alignment: .leading, spacing: 5) {
                header
                titleRow
                metaRow
                if let snippet = item.snippet(hideSpoilers: hideSpoilers) {
                    Text(verbatim: snippet)
                        .font(.footnote)
                        .foregroundStyle(Theme.ink.opacity(0.78))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.vertical, inset)
            .padding(.leading, inset + 2)
            .padding(.trailing, inset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.ink)
        .background(TicketBackground(stock: item.kind.stock, perforationX: stubWidth + inset * 2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 6) {
            AvatarView(urlString: account?.avatarURL, size: 18)
            Text(verbatim: account?.displayName ?? item.username)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if item.unread {
                Circle()
                    .fill(Theme.stamp)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("New")
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(verbatim: Format.short(item.date, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: item.title)
                .font(.system(.title3, design: .serif).weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let year = item.filmYear {
                Text(verbatim: year)
                    .font(.system(.footnote, design: .serif))
                    .foregroundStyle(Theme.ink.opacity(0.6))
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let stars = item.stars {
                Text(verbatim: stars)
                    .font(.footnote)
                    .foregroundStyle(Theme.stamp)
            }
            if item.liked && item.kind.isDiary {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.stamp)
            }
            if item.rewatch {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(Theme.ink.opacity(0.65))
            }
            Text(verbatim: item.metaLine)
                .font(.caption)
                .foregroundStyle(Theme.ink.opacity(0.65))
                .lineLimit(1)
        }
    }
}

/// Ticket stock with notches punched at the perforation and a dashed tear line.
struct TicketBackground: View {
    let stock: Color
    let perforationX: CGFloat
    var notchRadius: CGFloat = 9

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(stock)
                Path { path in
                    path.move(to: CGPoint(x: perforationX, y: notchRadius + 5))
                    path.addLine(to: CGPoint(x: perforationX, y: max(notchRadius + 5, height - notchRadius - 5)))
                }
                .stroke(Theme.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                Circle()
                    .frame(width: notchRadius * 2, height: notchRadius * 2)
                    .position(x: perforationX, y: 0)
                    .blendMode(.destinationOut)
                Circle()
                    .frame(width: notchRadius * 2, height: notchRadius * 2)
                    .position(x: perforationX, y: height)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}

struct PosterView: View {
    let urlString: String?
    let kind: ActivityKind

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Theme.ink.opacity(0.1))
            .overlay {
                if let urlString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else if phase.error != nil {
                            placeholder
                        } else {
                            ProgressView()
                                .tint(Theme.ink.opacity(0.4))
                        }
                    }
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: kind.symbol)
            .font(.title3)
            .foregroundStyle(Theme.ink.opacity(0.5))
    }
}

struct AvatarView: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Theme.ink.opacity(0.15))
            .overlay {
                if let urlString, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
            }
            .clipShape(Circle())
            .frame(width: size, height: size)
    }
}
