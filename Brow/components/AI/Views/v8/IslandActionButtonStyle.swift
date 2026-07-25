//
//  IslandActionButtonStyle.swift
//  Brow
//
//  Task 2.6: ported from the reference's `IslandActionButtonStyle`
//  (`IslandPanelView.swift`) onto Brow's own `V6Palette` — same three kinds
//  (primary/secondary/warning), same disabled-state dimming. Shared by
//  `ApprovalCardView`, `QuestionCardView`, and `CompletionCardView`.
//

import SwiftUI

struct IslandActionButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case warning
    }

    var kind: Kind
    var expands = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.8, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .lineLimit(1)
            .frame(maxWidth: expands ? .infinity : nil)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(backgroundColor(configuration.isPressed), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return V6Palette.paper.opacity(0.42) }

        switch kind {
        case .primary: return .black.opacity(0.88)
        case .warning: return .white
        case .secondary: return V6Palette.paper.opacity(0.78)
        }
    }

    private var strokeColor: Color {
        guard isEnabled else { return .white.opacity(0.07) }

        switch kind {
        case .primary: return V6Palette.paper.opacity(0.86)
        case .warning: return Color(red: 0.85, green: 0.55, blue: 0.15).opacity(0.42)
        case .secondary: return .white.opacity(0.07)
        }
    }

    private func backgroundColor(_ isPressed: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.055) }

        let pressedFactor: Double = isPressed ? 0.78 : 1
        switch kind {
        case .primary: return V6Palette.paper.opacity(pressedFactor)
        case .warning: return Color(red: 0.85, green: 0.55, blue: 0.15).opacity(pressedFactor)
        case .secondary: return Color.white.opacity(isPressed ? 0.11 : 0.065)
        }
    }
}
