//
//  CompletionCardView.swift
//  Brow
//
//  Task 2.6: the notification card for `session.phase == .completed` — the
//  session summary rendered as markdown, plus an optional reply field.
//
//  Native `AttributedString(markdown:)` + `Text`, no `swift-markdown-ui`
//  dependency: session summaries are short, single-paragraph prose (see
//  `SessionState`'s `resolvePermission`/`answerQuestion`/completion-event
//  summaries) — exactly what `AttributedString`'s built-in Markdown parser
//  handles (bold/italic/code/links), so there's nothing here a
//  block-level-aware renderer buys over the stdlib parser.
//
//  The reply field is a stub: a real send needs a follow-up-prompt
//  round-trip Brow's hook bridge doesn't expose (Task 2.9 took its safety
//  valve and left the approval continuation in `ClaudeCodeStore` rather
//  than moving it). For now `onReply` just receives the typed text and the
//  field clears — no bridge call yet.
//

import SwiftUI

struct CompletionCardView: View {
    var session: AgentSession
    var model: AIAppModel = .shared
    /// Stub hook for the reply field's send action. 2.9 wires this to the
    /// real continuation-based round-trip; until then it defaults to a
    /// no-op so the field is harmless to show.
    var onReply: (String) -> Void = { _ in }

    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Done")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(IslandStatus.completed)
                Spacer(minLength: 0)
            }

            if !session.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(summaryAttributedString)
                    .font(.system(size: 13))
                    .foregroundStyle(V6Palette.paper.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                TextField("Reply…", text: $replyText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(V6Palette.paper)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(V6Palette.paper.opacity(0.06)))
                    .onSubmit { sendReply() }

                Button("Send") { sendReply() }
                    .buttonStyle(IslandActionButtonStyle(kind: .primary))
                    .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V6Palette.ink)
    }

    private var summaryAttributedString: AttributedString {
        (try? AttributedString(markdown: session.summary)) ?? AttributedString(session.summary)
    }

    private func sendReply() {
        let trimmed = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onReply(trimmed)
        replyText = ""
    }
}

// MARK: - Previews

#Preview("CompletionCardView — with summary") {
    CompletionCardView(
        session: AgentSession(
            id: "s1", title: "Brow · feature/open-island-parity", tool: .claudeCode,
            phase: .completed,
            summary: "Refactored **AIAppModel** to own `SessionState`, added tests, and fixed a race in `resolvePermission`."
        ),
        model: AIAppModel()
    )
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
}

#Preview("CompletionCardView — no summary") {
    CompletionCardView(
        session: AgentSession(
            id: "s2", title: "docs-site · main", tool: .codex,
            phase: .completed,
            summary: ""
        ),
        model: AIAppModel()
    )
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
}
