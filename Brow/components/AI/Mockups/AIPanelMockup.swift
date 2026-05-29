import SwiftUI

// MARK: - Mockup-only models
//
// Self-contained fake data so this file renders in Preview without touching
// ClaudeCodeStore. Once the design is approved, we'll wire these into the
// real PendingApproval / SessionState models.

private enum MockSection: String, CaseIterable, Hashable {
    case monitor, approve, ask, jump

    var label: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .monitor: return "rectangle.grid.2x2"
        case .approve: return "checkmark.shield"
        case .ask:     return "questionmark.bubble"
        case .jump:    return "arrow.up.right.square"
        }
    }
}

private enum MockTaskStatus: Equatable {
    case working(String)
    case done(String)
    case running       // collapsed row, blue dot
    case completed     // collapsed row, green dot

    var bodyColor: Color {
        switch self {
        case .working:   return Color(red: 0.40, green: 0.65, blue: 1.00)
        case .done:      return Color(red: 0.45, green: 0.85, blue: 0.55)
        default:         return .clear
        }
    }
    var bodyText: String? {
        switch self {
        case .working(let s): return s
        case .done(let s):    return s
        default:              return nil
        }
    }
    var dotColor: Color {
        switch self {
        case .working, .running: return Color(red: 0.40, green: 0.65, blue: 1.00)
        case .done, .completed:  return Color(red: 0.45, green: 0.85, blue: 0.55)
        }
    }
}

private struct MockTask: Identifiable {
    let id = UUID()
    let title: String
    let userPrompt: String?
    let status: MockTaskStatus
    let agent: String
    let terminal: String
    let timeAgo: String
    let isHighlighted: Bool
}

private struct MockDiffLine: Identifiable {
    enum Kind { case context, added, removed }
    let id = UUID()
    let lineNumber: Int?
    let kind: Kind
    let text: String
}

private struct MockPermission {
    let toolName: String
    let target: String
    let diff: [MockDiffLine]
    let added: Int
    let removed: Int
}

private struct MockAskOption: Identifiable {
    let id = UUID()
    let shortcut: String   // "K1" / "K2" / "K3"
    let label: String
    let isSelected: Bool
}

// MARK: - Shared mock data

private let mockTasks: [MockTask] = [
    .init(title: "fix auth bug",
          userPrompt: "You: fix the auth bug in middleware",
          status: .working("Writing middleware.ts"),
          agent: "Claude", terminal: "iTerm", timeAgo: "27m",
          isHighlighted: true),
    .init(title: "backend server",
          userPrompt: nil, status: .running,
          agent: "Codex", terminal: "Terminal", timeAgo: "1h",
          isHighlighted: false),
    .init(title: "optimize queries",
          userPrompt: nil, status: .completed,
          agent: "Gemini", terminal: "Ghostty", timeAgo: "5h",
          isHighlighted: false),
]

private let mockPermission = MockPermission(
    toolName: "Edit",
    target: "src/auth/middleware.ts",
    diff: [
        .init(lineNumber: 12, kind: .context, text: "const verify = (token) =>"),
        .init(lineNumber: 13, kind: .removed, text: "  jwt.verify(token);"),
        .init(lineNumber: 13, kind: .added,   text: "  if (!token) throw new"),
        .init(lineNumber: 14, kind: .added,   text: "    AuthError('missing');"),
        .init(lineNumber: 15, kind: .context, text: "  return jwt.verify(toke…"),
    ],
    added: 3, removed: 1
)

private let mockAskOptions: [MockAskOption] = [
    .init(shortcut: "K1", label: "Production",  isSelected: true),
    .init(shortcut: "K2", label: "Staging",     isSelected: false),
    .init(shortcut: "K3", label: "Local only",  isSelected: false),
]

// MARK: - Container with notch cutout + bottom tab bar
//
// Wraps any section in a panel that drops out of the notch. The top of the
// panel has a NotchShape-derived cutout so the MacBook camera cluster stays
// visible. The bottom tab bar floats just below the panel like a dock.

private struct AINotchPanel<Content: View>: View {
    let section: MockSection
    @ViewBuilder var content: () -> Content

    // Brow's `mainSize` notch is ~210×32; leaving a slightly larger inset
    // so the cutout reads as "around the notch" not "on top of it".
    private let notchWidth: CGFloat = 220
    private let notchHeight: CGFloat = 38

    var body: some View {
        // No persistent tab bar — the panel auto-switches between sections
        // based on store state (pending approval → Approve, asked question
        // → Ask, click row → Jump, otherwise → Monitor).
        panel
    }

    private var panel: some View {
        content()
            .padding(.top, notchHeight + 6)
            .padding([.horizontal, .bottom], 0)
            .background(
                panelShape
                    .fill(
                        LinearGradient(
                            colors: [Color.black.opacity(0.95), Color.black.opacity(0.88)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            )
            .overlay(
                panelShape
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 8)
    }

    /// Outer rounded rect minus a centered notch-shaped cutout at the top
    /// so the camera cluster stays visible.
    private var panelShape: some Shape {
        PanelWithNotchCutout(
            cornerRadius: 18,
            notchWidth: notchWidth,
            notchHeight: notchHeight,
            notchTopRadius: 6,
            notchBottomRadius: 14
        )
    }

}

/// Rounded-rect panel with a NotchShape cutout punched out of the top edge.
private struct PanelWithNotchCutout: Shape {
    let cornerRadius: CGFloat
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let notchTopRadius: CGFloat
    let notchBottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let outer = Path(roundedRect: rect, cornerRadius: cornerRadius, style: .continuous)

        let cutoutRect = CGRect(
            x: rect.midX - notchWidth / 2,
            y: rect.minY,
            width: notchWidth,
            height: notchHeight
        )
        let notch = NotchShape(
            topCornerRadius: notchTopRadius,
            bottomCornerRadius: notchBottomRadius
        ).path(in: cutoutRect)

        // Subtract notch from outer via even-odd fill rule.
        var combined = Path()
        combined.addPath(outer)
        combined.addPath(notch)
        return combined
    }
}

// MARK: - Sections

private struct MonitorSection: View {
    let highlightIsJumpHover: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(mockTasks.enumerated()), id: \.element.id) { index, task in
                row(task)
                if index < mockTasks.count - 1 {
                    Divider().overlay(Color.white.opacity(0.06))
                        .padding(.leading, task.isHighlighted ? 0 : 24)
                }
            }
        }
        .padding(.vertical, 14)
        .frame(width: 480)
    }

    @ViewBuilder
    private func row(_ task: MockTask) -> some View {
        if task.isHighlighted {
            highlightedRow(task)
        } else {
            collapsedRow(task)
        }
    }

    private func highlightedRow(_ task: MockTask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BrowMascot(state: .working, size: 30).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                if let prompt = task.userPrompt {
                    Text(prompt)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                }
                if let body = task.status.bodyText {
                    Text(body)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(task.status.bodyColor)
                        .padding(.top, 1)
                }
            }
            Spacer(minLength: 8)
            tags(task)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func collapsedRow(_ task: MockTask) -> some View {
        HStack(spacing: 12) {
            Circle().fill(task.status.dotColor).frame(width: 8, height: 8)
            Text(task.title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            Spacer(minLength: 8)
            tags(task)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            (highlightIsJumpHover && task.title == "optimize queries")
                ? Color.white.opacity(0.06) : .clear
        )
    }

    private func tags(_ task: MockTask) -> some View {
        HStack(spacing: 6) {
            pill(task.agent); pill(task.terminal)
            Text(task.timeAgo).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }
    private func pill(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.09)))
    }
}

private struct ApproveSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.62, blue: 0.20))
                    .frame(width: 7, height: 7)
                Text("Permission Request")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                BrowMascot(state: .attention, size: 22)
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.20))
                Text(mockPermission.toolName)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                Text(mockPermission.target)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
            }

            diffBlock

            HStack(spacing: 8) {
                Text("+\(mockPermission.added)")
                    .foregroundStyle(Color(red: 0.45, green: 0.85, blue: 0.55))
                Text("-\(mockPermission.removed)")
                    .foregroundStyle(Color(red: 1.00, green: 0.45, blue: 0.45))
                Spacer()
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))

            HStack(spacing: 10) {
                actionButton("Deny", "⌘N", prominent: false)
                actionButton("Allow", "⌘Y", prominent: true)
            }
        }
        .padding(16)
        .frame(width: 480)
    }

    private var diffBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(mockPermission.diff) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(line.lineNumber.map(String.init) ?? "")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 18, alignment: .trailing)
                    Text(prefix(line.kind))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(prefixColor(line.kind))
                        .frame(width: 10, alignment: .center)
                    Text(line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(textColor(line.kind))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(rowBG(line.kind))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.05), lineWidth: 0.5))
    }

    private func prefix(_ k: MockDiffLine.Kind) -> String {
        switch k { case .context: return " "; case .added: return "+"; case .removed: return "-" }
    }
    private func prefixColor(_ k: MockDiffLine.Kind) -> Color {
        switch k {
        case .context: return .clear
        case .added:   return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .removed: return Color(red: 1.00, green: 0.45, blue: 0.45)
        }
    }
    private func textColor(_ k: MockDiffLine.Kind) -> Color {
        switch k {
        case .context: return .white.opacity(0.65)
        case .added:   return Color(red: 0.78, green: 0.95, blue: 0.82)
        case .removed: return Color(red: 1.00, green: 0.78, blue: 0.78)
        }
    }
    @ViewBuilder
    private func rowBG(_ k: MockDiffLine.Kind) -> some View {
        switch k {
        case .added:   Color(red: 0.10, green: 0.30, blue: 0.15).opacity(0.55)
        case .removed: Color(red: 0.35, green: 0.12, blue: 0.12).opacity(0.55)
        case .context: Color.clear
        }
    }

    private func actionButton(_ label: String, _ shortcut: String, prominent: Bool) -> some View {
        Button {} label: {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(prominent ? .black : .white)
                Text(shortcut).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(prominent ? .black.opacity(0.5) : .white.opacity(0.45))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(prominent ? Color.white : Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(prominent ? .clear : Color.white.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct AskSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(red: 0.45, green: 0.85, blue: 0.55))
                    .frame(width: 7, height: 7)
                Text("Claude asks")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                BrowMascot(state: .working, size: 22)
            }

            Text("Which deployment target?")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)

            VStack(spacing: 6) {
                ForEach(mockAskOptions) { opt in
                    HStack(spacing: 12) {
                        Text(opt.shortcut)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(opt.isSelected ? 0.95 : 0.55))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(opt.isSelected
                                          ? Color(red: 0.20, green: 0.40, blue: 0.30).opacity(0.85)
                                          : Color.white.opacity(0.08))
                            )

                        Text(opt.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)

                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(opt.isSelected
                                  ? Color(red: 0.18, green: 0.32, blue: 0.24).opacity(0.6)
                                  : Color.white.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(opt.isSelected
                                    ? Color(red: 0.30, green: 0.70, blue: 0.45).opacity(0.6)
                                    : Color.white.opacity(0.06),
                                    lineWidth: 0.6)
                    )
                }
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

// MARK: - Top-level

private struct AIPanelMockup: View {
    let section: MockSection
    let jumpHover: Bool

    init(section: MockSection = .monitor, jumpHover: Bool = false) {
        self.section = section
        self.jumpHover = jumpHover
    }

    var body: some View {
        AINotchPanel(section: section) {
            switch section {
            case .monitor:
                MonitorSection(highlightIsJumpHover: false)
            case .approve:
                ApproveSection()
            case .ask:
                AskSection()
            case .jump:
                MonitorSection(highlightIsJumpHover: true)
            }
        }
    }
}

// MARK: - Previews

private struct PreviewBackground<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [
                    Color(red: 0.20, green: 0.15, blue: 0.10),
                    Color(red: 0.40, green: 0.25, blue: 0.30),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            // Simulated menubar strip so the notch cutout has context.
            Rectangle()
                .fill(Color.black.opacity(0.6))
                .frame(height: 28)
            content
                .padding(.top, 16)
        }
    }
}

#Preview("Monitor", traits: .fixedLayout(width: 560, height: 360)) {
    PreviewBackground { AIPanelMockup(section: .monitor) }
}

#Preview("Approve", traits: .fixedLayout(width: 560, height: 460)) {
    PreviewBackground { AIPanelMockup(section: .approve) }
}

#Preview("Ask", traits: .fixedLayout(width: 560, height: 420)) {
    PreviewBackground { AIPanelMockup(section: .ask) }
}

#Preview("Jump (hover row)", traits: .fixedLayout(width: 560, height: 360)) {
    PreviewBackground { AIPanelMockup(section: .jump, jumpHover: true) }
}
