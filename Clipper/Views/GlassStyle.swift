import SwiftUI

// Apple's real glass APIs when the SDK and the device both have them, and the system
// material that preceded them otherwise. The `#if compiler` guard is what lets this file
// build against an older iOS SDK as well as the iOS 26 SDK.

/// A restrained glass surface. Used for grouping, not as the visual identity.
struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        content
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

/// The one prominent control on the main screen.
struct ProminentGlassButtonStyle: ViewModifier {
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(tint)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
        } else {
            legacy(content)
        }
        #else
        legacy(content)
        #endif
    }

    private func legacy(_ content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(tint)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
    }
}

/// A quieter glass control, used for the row-level play buttons.
struct SubtleGlassButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass).buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.circle)
        }
        #else
        content.buttonStyle(.bordered).buttonBorderShape(.circle)
        #endif
    }
}

extension View {
    func prominentGlass(tint: Color) -> some View {
        modifier(ProminentGlassButtonStyle(tint: tint))
    }

    func subtleGlass() -> some View {
        modifier(SubtleGlassButtonStyle())
    }
}

/// The app's backdrop. One very soft wash that reacts to recording state — enough
/// personality to feel alive, not enough to become decoration.
struct ClipperBackground: View {
    var isRecording: Bool

    var body: some View {
        ZStack {
            Color(.systemBackground)
            RadialGradient(
                colors: [
                    (isRecording ? Color.red : Color.accentColor).opacity(isRecording ? 0.16 : 0.08),
                    .clear,
                ],
                center: .init(x: 0.5, y: 0.28),
                startRadius: 8,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: isRecording)
    }
}
