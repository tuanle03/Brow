import SwiftUI

/// Closed-notch live activity for the AI tab — sibling to
/// `MusicLiveActivity` and `BrowFaceAnimation`. Shows when the user has
/// the AI tab selected so the notch reflects what they were looking at
/// before closing instead of falling back to the music / idle visualizer.
///
/// Layout matches `MusicLiveActivity`: a small icon on the left (here a
/// Claude-amber sparkle), a transparent middle that hugs the real notch
/// shape, and the eyebrows mascot on the right side. The mascot picks up
/// its state from `AITaskRegistry` so a pending approval pulses, a
/// working tool bounces, and an idle session breathes.
struct AILiveActivity: View {
    @ObservedObject private var registry = AITaskRegistry.shared
    @ObservedObject private var vm: BrowViewModel

    init(vm: BrowViewModel) {
        self._vm = ObservedObject(initialValue: vm)
    }

    var body: some View {
        HStack {
            sideIcon
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            HStack {
                BrowMascot(
                    state: mascotState,
                    pendingCount: pendingCount,
                    size: max(16, vm.effectiveClosedNotchHeight - 12)
                )
            }
            .frame(
                width: max(0, vm.effectiveClosedNotchHeight - 12),
                height: max(0, vm.effectiveClosedNotchHeight - 12),
                alignment: .center
            )
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    // MARK: - Left-side icon

    @ViewBuilder
    private var sideIcon: some View {
        Image(systemName: "sparkles")
            .font(.system(size: max(10, vm.effectiveClosedNotchHeight * 0.45),
                          weight: .semibold))
            .foregroundStyle(AIAgentKind.claudeCode.tint)
    }

    // MARK: - State derivation

    /// Mirrors the mascot states the open Monitor row uses, so opening
    /// the notch is just a scale-up of the same indicator.
    private var mascotState: BrowMascot.MascotState {
        switch registry.displayMode {
        case .approve, .ask:
            return .attention
        case .monitor, .jump:
            if registry.tasks.contains(where: { $0.status.isWorking }) {
                return .working
            }
            if registry.tasks.isEmpty {
                return .idle
            }
            return .idle
        }
    }

    /// Surfaced as a small red badge on the mascot when there's more than
    /// one waiting request — the user knows there's a queue to clear,
    /// not just one prompt.
    private var pendingCount: Int {
        registry.tasks.filter { $0.status == .pendingApproval || $0.status == .askingQuestion }.count
    }
}

private extension AITaskStatus {
    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}
