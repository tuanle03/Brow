import SwiftUI

/// Replaces `AISessionsTabView` as the content of the `.ai` notch tab.
/// Switches between Monitor / Approve / Ask sections automatically based
/// on `AITaskRegistry.displayMode`. The panel renders inside the existing
/// open notch container, so we don't draw our own background or notch
/// cutout — the surrounding `NotchLayout` already handles that.
struct AIPanel: View {
    @ObservedObject private var registry = AITaskRegistry.shared

    var body: some View {
        Group {
            switch registry.displayMode {
            case .approve(let taskID):
                if let task = registry.tasks.first(where: { $0.id == taskID }),
                   let approval = task.currentApproval {
                    AIApproveSection(task: task, approval: approval)
                } else {
                    AIMonitorSection(tasks: registry.tasks)
                }
            case .ask(let taskID):
                if let task = registry.tasks.first(where: { $0.id == taskID }),
                   let question = task.currentQuestion {
                    AIAskSection(task: task, question: question)
                } else {
                    AIMonitorSection(tasks: registry.tasks)
                }
            case .monitor, .jump:
                AIMonitorSection(tasks: registry.tasks)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Hard-clip so a tall preview never pushes content past the
        // notch shape at the top of the open notch container. Inner
        // ScrollViews handle the actual overflow — this is just a
        // safety belt.
        .clipped()
        .animation(.smooth(duration: 0.25), value: registry.displayMode)
    }
}

// MARK: - Shared row helpers

/// Pill-style label used for agent / terminal tags in every task row.
struct AITagPill: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
    }
}

extension AITask {
    /// Relative timestamp shown on the right of every row ("27m", "1h",
    /// "5h"). Coarse on purpose — we don't tick this view per second.
    var timeAgoShort: String {
        let elapsed = Date().timeIntervalSince(lastActivityAt)
        let s = Int(elapsed)
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    /// Display name for the terminal pill. Falls back to "Terminal" when
    /// we couldn't capture the host app at SessionStart (PR B).
    var terminalPillLabel: String {
        if let hint = terminalAppHint, !hint.isEmpty { return hint }
        return "Terminal"
    }
}

#Preview("AIPanel — Monitor (empty)") {
    AIPanel()
        .frame(width: 460, height: 180)
        .background(Color.black)
}
