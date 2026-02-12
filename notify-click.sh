#!/bin/bash
# Claude Code Notifications — click handler
# Called by terminal-notifier when the user clicks a notification.
# Activates the terminal app and switches to the correct tab if possible.
#
# Usage: notify-click.sh <TERM_PROGRAM> <TAB_ID> <SESSION_ID>
#   TERM_PROGRAM: WarpTerminal, iTerm.app, Apple_Terminal, JetBrains, or app name
#   TAB_ID:       Terminal-specific tab identifier (session ID, TTY path, uuid|port|pid, etc.)

TERM_APP="${1:-}"
TAB_ID="${2:-}"
SESSION_ID="${3:-}"

# Clear notification marker (user clicked the notification directly)
if [ -n "$SESSION_ID" ]; then
  rm -f "$HOME/.claude/.persistent-notifications/$SESSION_ID" 2>/dev/null
  # Kill background dismiss timer if running
  DPID_FILE="$HOME/.claude/.persistent-notifications/$SESSION_ID.dpid"
  if [ -f "$DPID_FILE" ]; then
    kill "$(cat "$DPID_FILE")" 2>/dev/null || true
    rm -f "$DPID_FILE"
  fi
fi

case "$TERM_APP" in
  iTerm.app)
    if [ -n "$TAB_ID" ]; then
      osascript -e "
        tell application \"iTerm2\"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if unique ID of s is \"$TAB_ID\" then
                  select t
                  set frontmost of w to true
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
      " 2>/dev/null
    else
      open -a "iTerm2"
    fi
    ;;

  Apple_Terminal)
    if [ -n "$TAB_ID" ]; then
      osascript -e "
        tell application \"Terminal\"
          activate
          repeat with w in windows
            if tty of selected tab of w is \"$TAB_ID\" then
              set frontmost of w to true
              exit repeat
            end if
          end repeat
        end tell
      " 2>/dev/null
    else
      open -a "Terminal"
    fi
    ;;

  WarpTerminal)
    open -a "Warp"
    ;;

  Cursor|"Visual Studio Code"|VSCodium)
    if [ -n "$TAB_ID" ]; then
      # Map app name to URI scheme for the VS Code extension
      case "$TERM_APP" in
        Cursor)   _scheme="cursor" ;;
        VSCodium) _scheme="vscodium" ;;
        *)        _scheme="vscode" ;;
      esac
      # open with URI scheme both activates the app AND delivers the URI to the extension.
      # If the extension isn't installed, the app still activates (graceful degradation).
      # If even the URI open fails, fall back to simple app activation.
      open "${_scheme}://anthropic.claude-code-notifications/focus?pids=${TAB_ID}" 2>/dev/null || \
        open -a "$TERM_APP" 2>/dev/null || true
    else
      open -a "$TERM_APP" 2>/dev/null || true
    fi
    ;;

  JetBrains)
    if [ -n "$TAB_ID" ]; then
      # Parse tab_id, port, and IDE PID from pipe-delimited TAB_ID
      IFS='|' read -r _tab_uuid _port _ide_pid <<< "$TAB_ID"
      # Focus the correct terminal tab via plugin's HTTP server
      curl -s --max-time 2 "http://127.0.0.1:${_port}/focus?tab_id=${_tab_uuid}" 2>/dev/null || true
      # Bring the IDE window to front (targets specific process by PID)
      if [ -n "$_ide_pid" ]; then
        osascript -e "
          tell application \"System Events\"
            try
              set frontmost of first process whose unix id is ${_ide_pid} to true
            end try
          end tell
        " 2>/dev/null || true
      fi
    else
      # No plugin installed: activate IntelliJ generically
      osascript -e 'tell application "IntelliJ IDEA" to activate' 2>/dev/null || \
        osascript -e 'tell application "IntelliJ IDEA CE" to activate' 2>/dev/null || true
    fi
    ;;

  "")
    # No terminal detected — do nothing (notification was still shown)
    ;;

  *)
    # Unknown terminal — try to open it as an app name
    open -a "$TERM_APP" 2>/dev/null || true
    ;;
esac
