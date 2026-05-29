#!/usr/bin/env bash
#
# Mimics Claude Code's hook script: POSTs fake hook events to the Brow
# bridge on 127.0.0.1:21064 so we can exercise the AI panel without
# actually running Claude Code.
#
# Usage:
#   ./tools/test-ai-bridge.sh                         # list scenarios
#   ./tools/test-ai-bridge.sh health                  # ping the bridge
#   ./tools/test-ai-bridge.sh session-start           # open a fake session
#   ./tools/test-ai-bridge.sh bash                    # Bash Permission Request
#   ./tools/test-ai-bridge.sh edit                    # Edit Permission Request (with diff)
#   ./tools/test-ai-bridge.sh write                   # Write Permission Request
#   ./tools/test-ai-bridge.sh user-prompt "what you want Claude to do"
#                                                    # UserPromptSubmit
#   ./tools/test-ai-bridge.sh notification            # Toast
#   ./tools/test-ai-bridge.sh ask                     # AskUserQuestion
#   ./tools/test-ai-bridge.sh stop                    # Claude is done
#   ./tools/test-ai-bridge.sh session-end             # close session
#   ./tools/test-ai-bridge.sh all                     # session-start + prompt + bash + edit + stop + session-end
#
# Notes:
# - `bash`, `edit`, `write` block until you click Allow/Deny in the notch
#   (or the bridge's 55s timeout fires). Run them in another terminal if
#   you want to keep the script free.
# - Override the session id with `SID=my-id ./tools/test-ai-bridge.sh ...`

set -u

BRIDGE="http://127.0.0.1:21064"
SID="${SID:-test-$$}"
CWD="${CWD:-/tmp/brow-ai-test}"

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
gray()  { printf '\033[90m%s\033[0m\n' "$*"; }

post() {
    local name="$1"
    local payload="$2"
    gray "→ POST /event  hook=${name}  session=${SID}"
    local resp
    # Long timeout for PermissionRequest since the bridge blocks until
    # the user decides.
    resp=$(curl -sS --max-time 90 \
        -H 'Content-Type: application/json' \
        -X POST "$BRIDGE/event" \
        -d "$payload") || {
        red "✗ Request failed (is Brow running?)"
        return 1
    }
    green "← $resp"
}

health() {
    bold "Pinging $BRIDGE/healthz"
    if curl -sS --max-time 2 "$BRIDGE/healthz" | grep -q '"ok":true'; then
        green "✓ Bridge is alive"
    else
        red "✗ No response — make sure Brow is running and the bridge started"
        return 1
    fi
}

session_start() {
    bold "SessionStart"
    post "SessionStart" "$(cat <<JSON
{
  "hook_event_name": "SessionStart",
  "session_id": "$SID",
  "cwd": "$CWD",
  "project_dir": "$CWD",
  "source": "startup",
  "model": "claude-sonnet-4-6"
}
JSON
    )"
}

permission_bash() {
    bold "PermissionRequest — Bash"
    gray "Notch should open with the Approve section showing the command."
    gray "Press ⌘Y allow, ⌘N deny, or wait 55s for timeout."
    post "PermissionRequest" "$(cat <<JSON
{
  "hook_event_name": "PermissionRequest",
  "session_id": "$SID",
  "tool_name": "Bash",
  "tool_input": { "command": "git push origin main --force" },
  "tool_use_id": "tu-$(date +%s)",
  "project_dir": "$CWD",
  "cwd": "$CWD",
  "permission_mode": "default"
}
JSON
    )"
}

permission_edit() {
    bold "PermissionRequest — Edit (with diff)"
    gray "Should render a red/green diff preview."
    post "PermissionRequest" "$(cat <<JSON
{
  "hook_event_name": "PermissionRequest",
  "session_id": "$SID",
  "tool_name": "Edit",
  "tool_input": {
    "file_path": "src/auth/middleware.ts",
    "old_string": "  jwt.verify(token);",
    "new_string": "  if (!token) throw new\n    AuthError('missing');"
  },
  "tool_use_id": "tu-$(date +%s)",
  "project_dir": "$CWD",
  "cwd": "$CWD",
  "permission_mode": "default",
  "permission_suggestions": [
    {
      "type": "addRules",
      "destination": "session",
      "behavior": "allow",
      "rules": [{ "toolName": "Edit", "ruleContent": "src/auth/**" }]
    }
  ]
}
JSON
    )"
}

permission_write() {
    bold "PermissionRequest — Write"
    post "PermissionRequest" "$(cat <<JSON
{
  "hook_event_name": "PermissionRequest",
  "session_id": "$SID",
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/tmp/hello.txt",
    "content": "line 1\nline 2\nline 3"
  },
  "tool_use_id": "tu-$(date +%s)",
  "project_dir": "$CWD",
  "cwd": "$CWD"
}
JSON
    )"
}

user_prompt() {
    local prompt="${2:-fix the auth bug in middleware}"
    bold "UserPromptSubmit"
    gray "Prompt: $prompt"
    # Escape backslashes and double quotes for embedding in JSON
    local escaped
    escaped=$(printf '%s' "$prompt" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    post "UserPromptSubmit" "$(cat <<JSON
{
  "hook_event_name": "UserPromptSubmit",
  "session_id": "$SID",
  "cwd": "$CWD",
  "prompt": $escaped
}
JSON
    )"
}

notification() {
    bold "Notification"
    post "Notification" "$(cat <<JSON
{
  "hook_event_name": "Notification",
  "session_id": "$SID",
  "message": "Heads up — Claude needs your attention",
  "project_dir": "$CWD"
}
JSON
    )"
}

ask_user_question() {
    bold "AskUserQuestion (rendered via Notification + auto-allow)"
    post "PermissionRequest" "$(cat <<JSON
{
  "hook_event_name": "PermissionRequest",
  "session_id": "$SID",
  "tool_name": "AskUserQuestion",
  "tool_input": {
    "question": "Which deployment target?",
    "questions": [{
      "question": "Which deployment target?",
      "options": ["Production", "Staging", "Local only"]
    }]
  },
  "tool_use_id": "tu-$(date +%s)",
  "project_dir": "$CWD",
  "cwd": "$CWD"
}
JSON
    )"
}

stop_event() {
    bold "Stop — Claude finished responding"
    post "Stop" "$(cat <<JSON
{
  "hook_event_name": "Stop",
  "session_id": "$SID",
  "cwd": "$CWD",
  "project_dir": "$CWD"
}
JSON
    )"
}

session_end() {
    bold "SessionEnd"
    post "SessionEnd" "$(cat <<JSON
{
  "hook_event_name": "SessionEnd",
  "session_id": "$SID",
  "cwd": "$CWD",
  "project_dir": "$CWD",
  "reason": "logout"
}
JSON
    )"
}

run_all() {
    health || exit 1
    echo
    session_start; echo
    sleep 0.3
    user_prompt all "build a login screen with email + password"; echo
    sleep 0.3
    permission_bash; echo
    sleep 0.3
    permission_edit; echo
    sleep 0.3
    stop_event; echo
    sleep 0.3
    session_end
}

usage() {
    cat <<EOF
Usage: $0 <scenario>

Scenarios:
  health           Ping the bridge (GET /healthz)
  session-start    Open a fake Claude Code session
  user-prompt "…"  UserPromptSubmit — sets the "You: …" subtitle
  bash             Bash PermissionRequest (blocks until you decide)
  edit             Edit PermissionRequest with diff (blocks)
  write            Write PermissionRequest (blocks)
  notification     Toast notification
  ask              AskUserQuestion (renders the Ask section)
  stop             Stop event ("Claude is done")
  session-end      Close the fake session
  all              Run a typical sequence end-to-end

Env overrides:
  SID=<id>         Use a specific session id (default: test-\$\$)
  CWD=<path>       Use a specific project dir (default: /tmp/brow-ai-test)

Examples:
  $0 health
  SID=abc123 $0 bash
EOF
}

case "${1:-}" in
    health)         health ;;
    session-start)  session_start ;;
    user-prompt)    user_prompt "$@" ;;
    bash)           permission_bash ;;
    edit)           permission_edit ;;
    write)          permission_write ;;
    notification)   notification ;;
    ask)            ask_user_question ;;
    stop)           stop_event ;;
    session-end)    session_end ;;
    all)            run_all ;;
    ""|-h|--help)   usage ;;
    *)              red "Unknown scenario: $1"; echo; usage; exit 1 ;;
esac
