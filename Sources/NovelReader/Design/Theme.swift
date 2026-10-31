#if canImport(SwiftUI)
import SwiftUI
import NovelKit

/// Palette + typography shared by every screen.
struct Theme {
    let background: Color
    let secondaryBackground: Color
    let text: Color
    let secondaryText: Color
    let accent: Color

    static func of(_ theme: ReaderTheme) -> Theme {
        switch theme {
        case .paper:
            return Theme(
                background: Color(red: 0.98, green: 0.97, blue: 0.95),
                secondaryBackground: Color(red: 0.94, green: 0.93, blue: 0.90),
                text: Color(red: 0.15, green: 0.14, blue: 0.13),
                secondaryText: Color(red: 0.45, green: 0.44, blue: 0.42),
                accent: Color(red: 0.62, green: 0.35, blue: 0.20)
            )
        case .sepia:
            return Theme(
                background: Color(red: 0.96, green: 0.92, blue: 0.83),
                secondaryBackground: Color(red: 0.91, green: 0.86, blue: 0.76),
                text: Color(red: 0.24, green: 0.19, blue: 0.12),
                secondaryText: Color(red: 0.47, green: 0.40, blue: 0.30),
                accent: Color(red: 0.60, green: 0.40, blue: 0.18)
            )
        case .night:
            return Theme(
                background: Color(red: 0.13, green: 0.13, blue: 0.14),
                secondaryBackground: Color(red: 0.19, green: 0.19, blue: 0.20),
                text: Color(red: 0.80, green: 0.80, blue: 0.78),
                secondaryText: Color(red: 0.55, green: 0.55, blue: 0.54),
                accent: Color(red: 0.85, green: 0.62, blue: 0.35)
            )
        case .black:
            return Theme(
                background: .black,
                secondaryBackground: Color(red: 0.10, green: 0.10, blue: 0.10),
                text: Color(red: 0.72, green: 0.72, blue: 0.70),
                secondaryText: Color(red: 0.45, green: 0.45, blue: 0.44),
                accent: Color(red: 0.80, green: 0.58, blue: 0.30)
            )
        }
    }
}

enum Palette {
    static let accent = Color(red: 0.72, green: 0.36, blue: 0.18)
    static let coverPlaceholder = LinearGradient(
        colors: [Color(red: 0.80, green: 0.72, blue: 0.63), Color(red: 0.62, green: 0.52, blue: 0.45)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// A cover image with a graceful placeholder (and no network dependency when
/// the URL is missing or relative).
struct CoverImage: View {
    let url: String?
    var width: CGFloat = 64
    var height: CGFloat = 88
    var cornerRadius: CGFloat = 6

    var body: some View {
        Group {
            if let url, let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Palette.coverPlaceholder
            Image(systemName: "book.closed")
                .font(.system(size: min(width, height) * 0.34))
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// Simple toast-ish banner used for import results and errors.
struct Banner: View {
    let text: String
    var isError: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).font(.footnote)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isError ? Color.red.opacity(0.9) : Color.black.opacity(0.78), in: Capsule())
        .foregroundStyle(.white)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
