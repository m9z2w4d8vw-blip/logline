import SwiftUI

/// An auditorium after the lights go down: velvet seats, brass fittings, ticket stock.
enum Theme {
    static let velvet = Color(red: 0.118, green: 0.047, blue: 0.067)
    static let velvetRaised = Color(red: 0.173, green: 0.078, blue: 0.098)
    static let brass = Color(red: 0.890, green: 0.722, blue: 0.392)
    static let muted = Color(red: 0.792, green: 0.710, blue: 0.682)
    static let ink = Color(red: 0.149, green: 0.110, blue: 0.094)
    static let stamp = Color(red: 0.698, green: 0.208, blue: 0.157)
    static let paper = Color(red: 0.957, green: 0.918, blue: 0.835)
    static let butter = Color(red: 0.965, green: 0.886, blue: 0.635)
    static let mint = Color(red: 0.792, green: 0.902, blue: 0.851)
    static let rose = Color(red: 0.957, green: 0.784, blue: 0.784)
    static let lilac = Color(red: 0.851, green: 0.820, blue: 0.937)
    static let fog = Color(red: 0.886, green: 0.878, blue: 0.859)
}

extension ActivityKind {
    /// Each kind of activity prints on its own ticket stock.
    var stock: Color {
        switch self {
        case .diary, .review: return Theme.paper
        case .list, .listUpdate: return Theme.butter
        case .watchlist: return Theme.mint
        case .like: return Theme.rose
        case .follow: return Theme.lilac
        case .comment, .other: return Theme.fog
        }
    }
}

struct VelvetScreen: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Theme.velvet.ignoresSafeArea())
            .toolbarBackground(Theme.velvet, for: .navigationBar, .tabBar)
    }
}

extension View {
    func velvetScreen() -> some View {
        modifier(VelvetScreen())
    }
}
