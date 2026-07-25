//
//  QuestionCardView.swift
//  Brow
//
//  Task 2.6: the notification card for `session.phase == .waitingForAnswer`
//  — renders each `QuestionPromptItem` (question text + a vertical option
//  list, `allowsFreeform` options growing a text field), collects answers
//  into `[String: String]` keyed by the question text, and submits via
//  `AIAppModel.answer(sessionID:answers:)`. Simplified from the reference's
//  `StructuredQuestionPromptView` (dropped the standalone global reply
//  field / hover states — Brow's `PermissionResolution`/`QuestionPrompt`
//  round-trip only needs the answer map itself).
//

import SwiftUI

struct QuestionCardView: View {
    var session: AgentSession
    var model: AIAppModel = .shared

    /// Selected option IDs, keyed by question index. A `Set` so
    /// `multiSelect` questions can hold more than one; single-select
    /// questions just replace the set's one member on each tap.
    @State private var selections: [Int: Set<String>] = [:]
    /// Freeform text, keyed by `"<questionIndex>-<optionID>"`.
    @State private var freeformTexts: [String: String] = [:]

    private var prompt: QuestionPrompt? { session.questionPrompt }
    private var questions: [QuestionPromptItem] { prompt?.questions ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(prompt?.title.isEmpty == false ? prompt!.title : "Question")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandStatus.waitingForAnswer)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                questionRow(index: index, question: question)
            }

            Button("Submit") { submit() }
                .buttonStyle(IslandActionButtonStyle(kind: canSubmit ? .primary : .secondary, expands: true))
                .disabled(!canSubmit)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V6Palette.ink)
    }

    // MARK: - Per-question row

    @ViewBuilder
    private func questionRow(index: Int, question: QuestionPromptItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if questions.count > 1, !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(V6Palette.paper.opacity(0.5))
            }

            Text(question.question)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(V6Palette.paper.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(question.options) { option in
                    optionRow(index: index, question: question, option: option)
                }
            }
        }
    }

    // MARK: - Option row

    @ViewBuilder
    private func optionRow(index: Int, question: QuestionPromptItem, option: QuestionOption) -> some View {
        let isSelected = selections[index]?.contains(option.id) ?? false

        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(index: index, option: option, multiSelect: question.multiSelect)
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(option.label)
                            .font(.system(size: 12.2, weight: .medium))
                            .foregroundStyle(V6Palette.paper.opacity(isSelected ? 1 : 0.78))

                        if !option.description.isEmpty {
                            Text(option.description)
                                .font(.system(size: 10.5))
                                .foregroundStyle(V6Palette.paper.opacity(0.42))
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(IslandStatus.completed)
                    }
                }
                .contentShape(Rectangle())
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)

            if option.allowsFreeform, isSelected {
                TextField("Type your answer", text: freeformBinding(index: index, option: option))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? V6Palette.paper.opacity(0.1) : Color.white.opacity(0.03))
        )
    }

    // MARK: - Selection state

    private func toggle(index: Int, option: QuestionOption, multiSelect: Bool) {
        var set = selections[index] ?? []
        if set.contains(option.id) {
            set.remove(option.id)
        } else {
            if !multiSelect { set.removeAll() }
            set.insert(option.id)
        }
        selections[index] = set
    }

    private func freeformBinding(index: Int, option: QuestionOption) -> Binding<String> {
        let key = freeformKey(index: index, optionID: option.id)
        return Binding(
            get: { freeformTexts[key] ?? "" },
            set: { freeformTexts[key] = $0 }
        )
    }

    private func freeformKey(index: Int, optionID: String) -> String { "\(index)-\(optionID)" }

    private var canSubmit: Bool {
        guard !questions.isEmpty else { return false }
        return questions.indices.allSatisfy { !(selections[$0]?.isEmpty ?? true) }
    }

    // MARK: - Submit

    private func submit() {
        var answers: [String: String] = [:]

        for (index, question) in questions.enumerated() {
            let selectedIDs = selections[index] ?? []
            guard !selectedIDs.isEmpty else { continue }

            let values = question.options
                .filter { selectedIDs.contains($0.id) }
                .map { option -> String in
                    guard option.allowsFreeform else { return option.label }
                    let typed = freeformTexts[freeformKey(index: index, optionID: option.id)] ?? ""
                    return typed.isEmpty ? option.label : typed
                }

            answers[question.question] = values.joined(separator: ", ")
        }

        model.answer(sessionID: session.id, answers: answers)
    }
}

// MARK: - Previews

#Preview("QuestionCardView — single question") {
    QuestionCardView(
        session: AgentSession(
            id: "s1", title: "Brow · main", tool: .claudeCode,
            phase: .waitingForAnswer,
            summary: "Which package manager should I use?",
            questionPrompt: QuestionPrompt(
                title: "Which package manager?",
                questions: [
                    QuestionPromptItem(
                        question: "Which package manager should I use?",
                        header: "Answer needed",
                        options: [
                            QuestionOption(label: "npm", description: "Node's default"),
                            QuestionOption(label: "pnpm", description: "Faster, disk-efficient"),
                            QuestionOption(label: "Other", allowsFreeform: true),
                        ]
                    ),
                ]
            )
        ),
        model: AIAppModel()
    )
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
}
