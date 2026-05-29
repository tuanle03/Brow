import SwiftUI

/// Renders Claude Code's `AskUserQuestion` as a notification-style card.
/// v1 is read-only — the hook API only round-trips allow/deny, so we
/// can't actually post the user's answer back. The card surfaces the
/// question + options (when Claude Code provides them) so the user knows
/// what to type back in the terminal. PR D will replace this with an
/// interactive picker once we have a side-channel to the agent.
struct AIAskSection: View {
    let task: AITask
    let question: AIQuestion

    private var registry: AITaskRegistry { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Same containment story as AIApproveSection: scrollable body
            // so a long question + many options doesn't blow out the notch
            // frame.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    questionText
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !question.options.isEmpty {
                        optionsList
                    } else {
                        Text("Answer the question in the terminal.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 0.45, green: 0.85, blue: 0.55))
                .frame(width: 7, height: 7)
            Text("\(task.agentKind.displayName) asks")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            BrowMascot(state: .working, size: 22)
        }
    }

    /// Renders the question text as Markdown when it parses cleanly, so
    /// **bold**, `code`, and [links](url) come through. Falls back to
    /// plain text on parse failure (e.g. unbalanced backticks). We use
    /// `.inlineOnlyPreservingWhitespace` so the body collapses to a
    /// single paragraph — block-level markdown (lists, headings) is left
    /// to the future Plan Review section.
    private var questionText: Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: question.text, options: options) {
            return Text(attributed)
        }
        return Text(question.text)
    }

    private var optionsList: some View {
        VStack(spacing: 6) {
            ForEach(question.options) { opt in
                HStack(spacing: 12) {
                    Text(opt.id)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                    Text(opt.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
                )
            }
        }
    }
}

#Preview("Ask — with options") {
    AIAskSection(
        task: AITask(
            id: "7af3e2",
            agentKind: .claudeCode,
            sessionID: "7af3e2",
            projectDirectory: "/Users/x/projects/Brow",
            terminalAppHint: "iTerm",
            userPrompt: nil,
            lastToolActivity: nil,
            status: .askingQuestion,
            lastActivityAt: Date(),
            currentApproval: nil,
            currentQuestion: AIQuestion(
                text: "Which deployment target?",
                options: [
                    .init(id: "K1", label: "Production"),
                    .init(id: "K2", label: "Staging"),
                    .init(id: "K3", label: "Local only"),
                ]
            )
        ),
        question: AIQuestion(
            text: "Which deployment target?",
            options: [
                .init(id: "K1", label: "Production"),
                .init(id: "K2", label: "Staging"),
                .init(id: "K3", label: "Local only"),
            ]
        )
    )
    .frame(width: 460, height: 280)
    .background(Color.black)
}
