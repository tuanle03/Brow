import SwiftUI
import Defaults

/// Brow's AI Sessions mascot — themed for the project name ("brow" =
/// eyebrows): two eyes with two expressive brows, plus a mouth that changes
/// shape per state. Drawn entirely in SwiftUI shapes so it scales cleanly,
/// re-tints to match accent colour, and stays under 50 KB of binary impact.
///
/// State maps directly to the integration the rest of PR #4–#6 ship:
/// - `.hidden` while no Claude Code session is alive — the mascot vanishes.
/// - `.idle` once a session is registered, no pending approvals.
/// - `.working` while the bridge has just heard from a session and we're
///   waiting on Claude to finish.
/// - `.attention` while the FIFO queue has at least one pending request.
/// - `.approved` / `.denied` flash briefly after the user resolves an entry.
///
/// All animation phases are driven by `TimelineView` so the view continues
/// to animate even when the parent isn't redrawing for other reasons.
struct BrowMascot: View {
    var state: MascotState
    var pendingCount: Int = 0
    var size: CGFloat = 24

    @Default(.selectedAIMascotVisualizer) private var aiMascotVisualizer

    var body: some View {
        if state == .hidden {
            EmptyView()
        } else if let lottie = aiMascotVisualizer {
            // User-picked Lottie replaces the built-in SwiftUI mascot.
            // Same scale rules as the music visualizer so the value the
            // user dials in stays consistent across both slots.
            LottieView(url: lottie.url, speed: lottie.speed, loopMode: .loop)
                .scaleEffect(lottie.scale, anchor: .center)
                .frame(width: size + 14, height: size + 14)
                .overlay(alignment: .topTrailing) { badge }
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = animationPhase(at: t)

                ZStack {
                    glowRing(phase: phase)

                    face
                        .scaleEffect(scale(phase: phase))
                        .offset(y: offset(phase: phase))

                    badge
                }
                .frame(width: size + 14, height: size + 14)
            }
        }
    }

    // MARK: - Mascot states

    enum MascotState: Equatable {
        case hidden
        case idle
        case working
        case attention
        case approved
        case denied
    }

    // MARK: - Face

    private var face: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.18, blue: 0.22),
                            Color(red: 0.08, green: 0.08, blue: 0.10)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(borderColor, lineWidth: 0.8)
                )
                .overlay(
                    // Tint overlay for approved/denied flash states.
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(flashColor)
                        .opacity(flashOpacity)
                )
                .frame(width: size, height: size)

            // Brows
            HStack(spacing: size * 0.18) {
                browShape(angle: leftBrowAngle)
                browShape(angle: -leftBrowAngle)
            }
            .offset(y: -size * 0.20 - browRaise)

            // Eyes
            HStack(spacing: size * 0.16) {
                eye
                eye
            }
            .offset(y: -size * 0.02)

            // Mouth
            mouth
                .offset(y: size * 0.22)
        }
    }

    @ViewBuilder
    private var eye: some View {
        let eyeWidth = size * 0.22
        let enlarged = state == .attention
        if state == .approved {
            // Happy closed eye — flat arc instead of a circle.
            Capsule()
                .fill(Color(red: 0.05, green: 0.05, blue: 0.08))
                .frame(width: eyeWidth, height: eyeWidth * 0.45)
        } else {
            Circle()
                .fill(Color.white)
                .frame(
                    width: enlarged ? eyeWidth * 1.15 : eyeWidth,
                    height: enlarged ? eyeWidth * 1.15 : eyeWidth
                )
                .overlay(
                    Circle()
                        .fill(Color.black)
                        .frame(width: size * 0.10, height: size * 0.10)
                        .offset(pupilOffset)
                )
        }
    }

    private func browShape(angle: Double) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.95))
            .frame(width: size * 0.28, height: max(1.5, size * 0.075))
            .rotationEffect(.degrees(angle))
    }

    @ViewBuilder
    private var mouth: some View {
        switch state {
        case .approved:
            SmilePath(curve: 1)
                .stroke(.white.opacity(0.9), style: .init(lineWidth: max(1.2, size * 0.05), lineCap: .round))
                .frame(width: size * 0.30, height: size * 0.12)
        case .denied:
            SmilePath(curve: -1)
                .stroke(.white.opacity(0.9), style: .init(lineWidth: max(1.2, size * 0.05), lineCap: .round))
                .frame(width: size * 0.30, height: size * 0.12)
        case .attention:
            Circle()
                .stroke(.white.opacity(0.85), lineWidth: max(1, size * 0.045))
                .frame(width: size * 0.10, height: size * 0.10)
        case .working:
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: size * 0.16, height: max(1, size * 0.04))
        case .idle:
            SmilePath(curve: 0.4)
                .stroke(.white.opacity(0.7), style: .init(lineWidth: max(1, size * 0.04), lineCap: .round))
                .frame(width: size * 0.20, height: size * 0.08)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private func glowRing(phase: AnimationPhase) -> some View {
        if state == .attention {
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.pink, .cyan, .purple],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: size + 6, height: size + 6)
                .opacity(0.65 + 0.30 * phase.glow)
                .scaleEffect(1.0 + 0.08 * phase.glow)
        }
    }

    @ViewBuilder
    private var badge: some View {
        if pendingCount > 1 {
            Text("\(pendingCount)")
                .font(.system(size: max(9, size * 0.32), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, max(4, size * 0.14))
                .padding(.vertical, max(1, size * 0.05))
                .background(Capsule().fill(Color.red))
                .offset(x: size * 0.45, y: -size * 0.45)
        }
    }

    // MARK: - Visual state derivations

    private var borderColor: Color {
        switch state {
        case .working:   return .cyan.opacity(0.55)
        case .attention: return .pink.opacity(0.7)
        case .approved:  return .green.opacity(0.7)
        case .denied:    return .red.opacity(0.7)
        default:         return .white.opacity(0.10)
        }
    }
    private var flashColor: Color {
        switch state {
        case .approved: return .green
        case .denied:   return .red
        default:        return .clear
        }
    }
    private var flashOpacity: Double {
        switch state {
        case .approved, .denied: return 0.25
        default: return 0
        }
    }
    private var leftBrowAngle: Double {
        switch state {
        case .working:   return 8     // tilt down inward = focused
        case .attention: return -18   // raised outer = surprised
        case .approved:  return -6    // soft up
        case .denied:    return 18    // angry down
        default:         return 0
        }
    }
    private var browRaise: CGFloat {
        switch state { case .attention: return size * 0.05; default: return 0 }
    }
    private var pupilOffset: CGSize {
        switch state {
        case .working:   return CGSize(width: size * 0.04, height: 0)
        case .attention: return CGSize(width: 0, height: -size * 0.02)
        default:         return .zero
        }
    }

    // MARK: - Animation phases

    private struct AnimationPhase {
        let breathe: CGFloat   // 0...1, slow sinusoid for idle
        let bounce: CGFloat    // -1...1, faster sinusoid for working/attention
        let glow: CGFloat      // 0...1, glow pulse for attention
    }

    private func animationPhase(at time: TimeInterval) -> AnimationPhase {
        AnimationPhase(
            breathe: CGFloat(0.5 + 0.5 * sin(time * 2 * .pi / 3.0)),
            bounce:  CGFloat(sin(time * 2 * .pi / (state == .attention ? 0.5 : 0.9))),
            glow:    CGFloat(0.5 + 0.5 * sin(time * 2 * .pi / 0.8))
        )
    }

    private func scale(phase: AnimationPhase) -> CGFloat {
        switch state {
        case .idle:       return 1.0 + 0.02 * phase.breathe
        case .working:    return 1.0 + 0.04 * abs(phase.bounce)
        case .attention:  return 1.0 + 0.08 * abs(phase.bounce)
        default:          return 1.0
        }
    }
    private func offset(phase: AnimationPhase) -> CGFloat {
        switch state {
        case .working:    return -1.5 * phase.bounce
        case .attention:  return -3.0 * phase.bounce
        default:          return 0
        }
    }
}

/// Quadratic-curve mouth shape. `curve > 0` smiles, `curve < 0` frowns.
private struct SmilePath: Shape {
    var curve: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let mid = rect.midX
        let control = CGPoint(
            x: mid,
            y: curve > 0 ? rect.maxY + (curve * 4) : rect.minY + (curve * 4)
        )
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: control)
        return path
    }
}

#Preview("BrowMascot — all states", traits: .sizeThatFitsLayout) {
    HStack(spacing: 24) {
        ForEach(
            [
                ("idle",      BrowMascot.MascotState.idle,      0),
                ("working",   BrowMascot.MascotState.working,   0),
                ("attention", BrowMascot.MascotState.attention, 3),
                ("approved",  BrowMascot.MascotState.approved,  0),
                ("denied",    BrowMascot.MascotState.denied,    0),
            ],
            id: \.0
        ) { label, state, pending in
            VStack(spacing: 8) {
                BrowMascot(state: state, pendingCount: pending, size: 36)
                Text(label)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(width: 70)
        }
    }
    .padding(28)
    .background(Color.black)
}
