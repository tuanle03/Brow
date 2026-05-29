import SwiftUI

/// Permission Request card for the `.approve` display mode. Renders the
/// pending tool call's target (Bash command, file path, …) and the
/// per-suggestion buttons Claude Code shipped with the request, plus
/// Deny. Keyboard shortcuts mirror what the agent's native dialog uses:
/// `⌘Y` allow, `⌘N` deny.
struct AIApproveSection: View {
    let task: AITask
    let approval: PendingApproval

    private var registry: AITaskRegistry { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header collapses Permission Request + the tool name + the
            // queue pill into a single row. The previous two-row layout
            // ate ~60pt of the open notch's 240pt — too much when the
            // preview body needs to show a Bash command or a JSON dump.
            compactHeader
            // Preview can be long (multi-line command, big diff). Wrap
            // it in a ScrollView with layoutPriority so it claims the
            // remaining vertical space *before* the action row, never
            // collapses to zero, and content scrolls when oversized.
            ScrollView(.vertical, showsIndicators: false) {
                preview
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .scrollBounceBehavior(.basedOnSize)

            actionRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Header (orange dot + tool name + queue pill + mascot, one row)

    private var compactHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(red: 1.0, green: 0.62, blue: 0.20))
                .frame(width: 7, height: 7)
            Image(systemName: toolSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(toolTint)
            Text(approval.toolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if let target = approvalShortTarget {
                Text(target)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if queueTotal > 1 {
                Text("\(queueIndex)/\(queueTotal)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color(red: 1.0, green: 0.62, blue: 0.20).opacity(0.22))
                    )
                    .overlay(
                        Capsule().stroke(Color(red: 1.0, green: 0.62, blue: 0.20).opacity(0.5),
                                         lineWidth: 0.8)
                    )
            }
            Spacer(minLength: 6)
            BrowMascot(state: .attention, size: 20)
        }
    }

    /// 1-based position of this approval in the registry's pending queue
    /// (sorted newest-first by the registry). Lets the user see "I just
    /// approved one but there are 2 more in line" instead of mistaking a
    /// fresh request for the one they already resolved.
    private var queueIndex: Int {
        let pendingIDs = registry.tasks
            .filter { $0.status == .pendingApproval }
            .compactMap { $0.currentApproval?.id }
        return (pendingIDs.firstIndex(of: approval.id) ?? 0) + 1
    }

    private var queueTotal: Int {
        registry.tasks.filter { $0.status == .pendingApproval }.count
    }

    // MARK: - Preview body
    //
    // Bash: command in a monospaced code box.
    // Edit: old_string (red) → new_string (green) — a single-hunk diff
    //       without the per-line numbering of a real unified diff. Good
    //       enough for "I can read what's about to change" review.
    // Write: file content preview (first ~6 lines, dim).
    // Otherwise: tool input keys as a one-liner.

    @ViewBuilder
    private var preview: some View {
        // Resolve the per-tool primary text once and fall through to a
        // generic key/value dump when it's empty. The dump is also what
        // unknown tools land on (MCP tools, future Claude features) so
        // the user always sees *something* — an empty code box on
        // approve was the bug.
        let body: String = {
            switch approval.toolName {
            case "Bash":  return approval.toolInput["command"]?.asDisplayString ?? ""
            case "Write": return approval.toolInput["content"]?.asDisplayString ?? ""
            default:      return approval.targetDescription
            }
        }()

        if approval.toolName == "Edit" {
            editDiff
        } else if !body.isEmpty {
            codeBox(body, maxLines: approval.toolName == "Write" ? 5 : 3)
        } else {
            toolInputDump
        }
    }

    /// Last-resort preview: list every `tool_input` key + value so the
    /// approval card never hands the user a blank Allow / Deny pair.
    /// Used when the per-tool extraction returns empty (unknown MCP
    /// tools, schema changes from Claude Code, malformed payloads).
    private var toolInputDump: some View {
        let keys = approval.toolInput.keys.sorted()
        let lines: [String]
        if keys.isEmpty {
            lines = ["(no tool input)"]
        } else {
            lines = keys.map { key in
                let value = approval.toolInput[key]?.asDisplayString ?? ""
                let trimmed = value.count > 80 ? String(value.prefix(79)) + "…" : value
                return "\(key): \(trimmed)"
            }
        }
        return codeBox(lines.joined(separator: "\n"), maxLines: 6)
    }

    private func codeBox(_ text: String, maxLines: Int = 4) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .multilineTextAlignment(.leading)
            .lineLimit(maxLines)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(toolTint.opacity(0.3), lineWidth: 0.8)
            )
    }

    private var editDiff: some View {
        let oldText = approval.toolInput["old_string"]?.asDisplayString ?? ""
        let newText = approval.toolInput["new_string"]?.asDisplayString ?? ""
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(oldText.previewLines, id: \.self) { line in
                diffLine(prefix: "-", text: line,
                         bg: Color(red: 0.35, green: 0.12, blue: 0.12).opacity(0.55),
                         fg: Color(red: 1.00, green: 0.78, blue: 0.78))
            }
            ForEach(newText.previewLines, id: \.self) { line in
                diffLine(prefix: "+", text: line,
                         bg: Color(red: 0.10, green: 0.30, blue: 0.15).opacity(0.55),
                         fg: Color(red: 0.78, green: 0.95, blue: 0.82))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
    }

    private func diffLine(prefix: String, text: String, bg: Color, fg: Color) -> some View {
        HStack(spacing: 6) {
            Text(prefix)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(fg)
                .frame(width: 10, alignment: .center)
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(fg)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(bg)
    }

    // MARK: - Buttons

    private var actionRow: some View {
        HStack(spacing: 6) {
            actionButton("Deny", "⌘N", tint: .red, prominent: false) {
                registry.decide(approval.id, as: .deny)
            }
            .keyboardShortcut("n", modifiers: .command)

            ForEach(Array(approval.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                let shortcut: String? = (index == 0) ? "⌘⇧↵" : nil
                actionButton(suggestion.displayLabel, shortcut, tint: .cyan, prominent: false) {
                    registry.decide(approval.id, as: .allowWith(suggestion))
                }
                .modifier(ConditionalShortcut(active: index == 0,
                                              key: .return,
                                              modifiers: [.command, .shift]))
            }

            Spacer(minLength: 0)

            actionButton("Allow", "⌘Y", tint: .green, prominent: true) {
                registry.decide(approval.id, as: .allow)
            }
            .keyboardShortcut("y", modifiers: .command)
        }
    }

    private func actionButton(_ label: String,
                              _ shortcut: String?,
                              tint: Color,
                              prominent: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(prominent ? .black : .white)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(prominent ? .black.opacity(0.55) : .white.opacity(0.5))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(prominent ? 0 : 0.45), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tool styling

    private var toolSymbol: String {
        switch approval.toolName {
        case "Edit":  return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash":  return "terminal"
        case "Read":  return "doc.text"
        default:      return "wand.and.rays"
        }
    }

    private var toolTint: Color {
        switch approval.toolName {
        case "Edit":  return .yellow
        case "Write": return .orange
        case "Bash":  return .red
        case "Read":  return .blue
        default:      return .gray
        }
    }

    private var approvalShortTarget: String? {
        if let path = approval.toolInput["file_path"]?.asDisplayString {
            return (path as NSString).lastPathComponent
        }
        return nil
    }
}

// MARK: - Helpers

/// SwiftUI doesn't let us conditionally chain `.keyboardShortcut`. This
/// modifier wraps the conditional so we can attach ⌘⇧↵ only to the first
/// suggestion button.
private struct ConditionalShortcut: ViewModifier {
    let active: Bool
    let key: KeyEquivalent
    let modifiers: EventModifiers

    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(key, modifiers: modifiers)
        } else {
            content
        }
    }
}

private extension String {
    /// First few lines of a multi-line string, for diff preview. Bigger
    /// edits truncate so the row never overflows the notch height.
    var previewLines: [String] {
        let lines = split(whereSeparator: \.isNewline).map(String.init)
        return Array(lines.prefix(3))
    }
}

#Preview("Approve — Edit diff") {
    AIApproveSection(
        task: AITask(
            id: "7af3e2",
            agentKind: .claudeCode,
            sessionID: "7af3e2",
            projectDirectory: "/Users/x/projects/Brow",
            terminalAppHint: "iTerm",
            userPrompt: nil,
            lastToolActivity: nil,
            status: .pendingApproval,
            lastActivityAt: Date(),
            currentApproval: nil,
            currentQuestion: nil
        ),
        approval: PendingApproval(
            id: UUID(),
            receivedAt: Date(),
            sessionID: "7af3e2",
            toolName: "Edit",
            toolInput: [
                "file_path":  .string("src/auth/middleware.ts"),
                "old_string": .string("  jwt.verify(token);"),
                "new_string": .string("  if (!token) throw new\n    AuthError('missing');"),
            ],
            projectDirectory: "/Users/x/projects/Brow",
            suggestions: [],
            rawJSON: ""
        )
    )
    .frame(width: 460, height: 320)
    .background(Color.black)
}

#Preview("Approve — Bash") {
    AIApproveSection(
        task: AITask(
            id: "7af3e2",
            agentKind: .claudeCode,
            sessionID: "7af3e2",
            projectDirectory: "/Users/x/projects/Brow",
            terminalAppHint: "iTerm",
            userPrompt: nil,
            lastToolActivity: nil,
            status: .pendingApproval,
            lastActivityAt: Date(),
            currentApproval: nil,
            currentQuestion: nil
        ),
        approval: PendingApproval(
            id: UUID(),
            receivedAt: Date(),
            sessionID: "7af3e2",
            toolName: "Bash",
            toolInput: [
                "command": .string("git push origin main --force"),
            ],
            projectDirectory: "/Users/x/projects/Brow",
            suggestions: [],
            rawJSON: ""
        )
    )
    .frame(width: 460, height: 260)
    .background(Color.black)
}
