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

    var isHovering: Bool = false {
        didSet {
            guard oldValue != isHovering else { return }
            handleHoverChange()
        }
    }

    @ObservationIgnored
    private var openTask: Task<Void, Never>?

    private init() {}

    func expand() {
        openTask?.cancel()
        currentState = .open
    }

    func collapse() {
        openTask?.cancel()
        currentState = .closed
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
