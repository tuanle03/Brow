//
//  ContentView.swift
//  Brow
//

import SwiftUI

struct ContentView: View {
    private let coordinator = BrowViewCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            NotchLayout(coordinator: coordinator)
                .onHover { hovering in
                    coordinator.isHovering = hovering
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

#Preview {
    ContentView()
        .frame(width: 600, height: 200)
        .background(Color.gray)
}
