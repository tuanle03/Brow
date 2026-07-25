import Foundation

/// One selectable answer for a `QuestionPromptItem`.
struct QuestionOption: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var label: String
    var optionDescription: String?
}

/// One question in a `QuestionPrompt` (Claude's `AskUserQuestion` can ask
/// several at once) — an option list plus, optionally, a freeform field for
/// an answer that isn't one of the offered options.
struct QuestionPromptItem: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var question: String
    var header: String?
    var options: [QuestionOption]
    var allowsFreeform: Bool
}

/// A pending question attached to an `AgentSession` while its phase is
/// `.waitingForAnswer`. The answer round-trips back to the agent through
/// the blocked hook connection.
struct QuestionPrompt: Codable, Sendable, Equatable {
    var toolUseID: String?
    var items: [QuestionPromptItem]
}
