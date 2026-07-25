import Foundation

/// One selectable answer for a `QuestionPromptItem`. Ported from Open
/// Island's `AgentSession.QuestionOption` — `allowsFreeform` lives here
/// (not on the item) because a CLI-synthesized "Other" option is itself a
/// freeform slot sitting alongside ordinary label options.
struct QuestionOption: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var description: String
    /// When true, the submitted answer is the user's typed text, not the label.
    var allowsFreeform: Bool

    init(id: String = UUID().uuidString, label: String, description: String = "", allowsFreeform: Bool = false) {
        self.id = id
        self.label = label
        self.description = description
        self.allowsFreeform = allowsFreeform
    }
}

/// One question in a `QuestionPrompt` (Claude's `AskUserQuestion` can ask
/// several at once).
struct QuestionPromptItem: Codable, Sendable, Equatable {
    var question: String
    var header: String
    var options: [QuestionOption]
    var multiSelect: Bool

    init(question: String, header: String, options: [QuestionOption], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

/// A pending question attached to an `AgentSession` while its phase is
/// `.waitingForAnswer`. The answer round-trips back to the agent through
/// the blocked hook connection.
struct QuestionPrompt: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var questions: [QuestionPromptItem]
    /// Correlates the answer back to the originating hook call.
    var toolUseID: String?

    init(id: String = UUID().uuidString, title: String, questions: [QuestionPromptItem], toolUseID: String? = nil) {
        self.id = id
        self.title = title
        self.questions = questions
        self.toolUseID = toolUseID
    }
}
