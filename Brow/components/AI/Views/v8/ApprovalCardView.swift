//
//  ApprovalCardView.swift
//  Brow
//
//  Task 2.6: the notification card for `session.phase == .waitingForApproval`
//  — a command/target preview over three buttons (Deny / Allow once /
//  Always allow <tool>), ported from the reference's `approvalActionBody`
//  onto Brow's own palette + `PermissionResolution`. Buttons call
//  `AIAppModel.approve(sessionID:_:)` directly; the reducer
//  (`SessionState.resolvePermission`) clears `permissionRequest` and moves
//  the session back to `.running` — no HTTP continuation yet (that's 2.9).
//
//  `alwaysAllowResolution(toolName:)` is pulled out as a static, pure
//  function (not inlined in the button action) specifically so
//  `CardActionTests` can assert its shape without going through SwiftUI.
//

import SwiftUI

struct ApprovalCardView: View {
    var session: AgentSession
    var model: AIAppModel = .shared

    private var request: PermissionRequest? { session.permissionRequest }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wants permission")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(IslandStatus.waitingForApproval)

            VStack(alignment: .leading, spacing: 6) {
                Text(request?.summary ?? session.summary)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(V6Palette.paper.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)

                if let path = request?.affectedPath, !path.isEmpty {
                    Text(path)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(V6Palette.paper.opacity(0.42))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(V6Palette.paper.opacity(0.06)))

            HStack(spacing: 8) {
                Button(request?.secondaryActionTitle ?? "Deny") {
                    model.approve(sessionID: session.id, .deny())
                }
                .buttonStyle(IslandActionButtonStyle(kind: .secondary, expands: true))

                Button(request?.primaryActionTitle ?? "Allow once") {
                    model.approve(sessionID: session.id, .allowOnce())
                }
                .buttonStyle(IslandActionButtonStyle(kind: .warning, expands: true))

                if let toolName = request?.toolName {
                    Button("Always allow \(toolName)") {
                        model.approve(sessionID: session.id, Self.alwaysAllowResolution(toolName: toolName))
                    }
                    .buttonStyle(IslandActionButtonStyle(kind: .primary, expands: true))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V6Palette.ink)
    }

    /// The "Always allow <tool>" resolution: a session-scoped `addRules`
    /// permission update wrapped in `.allowOnce(updatedPermissions:)`,
    /// matching the reference's button action exactly (`destination: .session,
    /// behavior: .allow`, one rule for the tool name, no rule content — a
    /// blanket allow for that tool, not scoped to one path/command).
    static func alwaysAllowResolution(toolName: String) -> PermissionResolution {
        let rule = ClaudePermissionRuleValue(toolName: toolName)
        let update = ClaudePermissionUpdate.addRules(destination: .session, rules: [rule], behavior: .allow)
        return .allowOnce(updatedPermissions: [update])
    }
}

// MARK: - Previews

#Preview("ApprovalCardView — with tool name") {
    ApprovalCardView(
        session: AgentSession(
            id: "s1", title: "Brow · feature/open-island-parity", tool: .claudeCode,
            phase: .waitingForApproval,
            summary: "Wants to run rm -rf build/",
            permissionRequest: PermissionRequest(
                id: "p1", title: "Run command", summary: "rm -rf build/", affectedPath: "build/",
                toolName: "Bash"
            )
        ),
        model: AIAppModel()
    )
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
}

#Preview("ApprovalCardView — no tool name (no Always-allow button)") {
    ApprovalCardView(
        session: AgentSession(
            id: "s2", title: "docs-site · main", tool: .codex,
            phase: .waitingForApproval,
            summary: "Wants to edit README.md",
            permissionRequest: PermissionRequest(
                id: "p2", title: "Edit file", summary: "Edit README.md", affectedPath: "README.md"
            )
        ),
        model: AIAppModel()
    )
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
}
