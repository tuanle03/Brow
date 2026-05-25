//
//  NotchLayout.swift
//  Brow
//

import SwiftUI

struct NotchLayout: View {
    let coordinator: BrowViewCoordinator

    private var size: CGSize {
        switch coordinator.currentState {
        case .closed:
            return CGSize(width: NotchSize.closed.width, height: NotchSize.closed.height)
        case .hovered:
            return CGSize(width: NotchSize.hovered.width, height: NotchSize.hovered.height)
        case .open:
            return CGSize(width: NotchSize.open.width, height: NotchSize.open.height)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(bottomCornerRadius: coordinator.currentState == .open ? 18 : 10)
                .fill(.black)

            content
                .padding(.horizontal, coordinator.currentState == .open ? 16 : 8)
                .padding(.vertical, coordinator.currentState == .open ? 12 : 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: coordinator.currentState)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.currentState {
        case .closed:
            EmptyView()
        case .hovered:
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.white)
                    .font(.caption)
                Spacer(minLength: 0)
            }
        case .open:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.white)
                    Text("Brow")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer()
                }
                Text("Music · Calendar · HUD · Shelf coming soon")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
