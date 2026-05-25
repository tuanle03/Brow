//
//  BrowViewCoordinator.swift
//  Brow
//

import AppKit
import Observation

@MainActor
@Observable
final class BrowViewCoordinator {
    static let shared = BrowViewCoordinator()

    var currentState: NotchState = .closed
    var selectedScreenUUID: String?

    /// When non-nil, the notch renders a transient overlay (e.g. charging
    /// indicator) on top of its normal contents. Auto-dismisses after the
    /// peek's `duration`.
    var sneakPeek: SneakPeek?

    var isHovering: Bool = false {
        didSet {
            guard oldValue != isHovering else { return }
            handleHoverChange()
        }
    }

    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var sneakPeekDismissTask: Task<Void, Never>?

    private init() {}

    func expand() {
        openTask?.cancel()
        currentState = .open
    }

    func collapse() {
        openTask?.cancel()
        currentState = .closed
    }

    func showSneakPeek(_ kind: SneakPeekKind, duration: TimeInterval = 1.6) {
        let peek = SneakPeek(kind: kind, duration: duration)
        sneakPeek = peek
        sneakPeekDismissTask?.cancel()
        sneakPeekDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // Only dismiss if the same peek is still showing — a newer one
            // would have replaced it and scheduled its own dismiss.
            if self?.sneakPeek == peek {
                self?.sneakPeek = nil
            }
        }
    }

    private func handleHoverChange() {
        openTask?.cancel()
        if isHovering {
            currentState = .hovered
            openTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                self?.currentState = .open
            }
        } else {
            currentState = .closed
        }
    }
}
