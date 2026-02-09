#!/bin/bash
# Claude Code Notifications — click handler
# Called by terminal-notifier when the user clicks a notification.
# Activates the terminal app and switches to the correct tab if possible.
#
# Usage: notify-click.sh <TERM_PROGRAM> <TAB_ID>
#   TERM_PROGRAM: WarpTerminal, iTerm.app, Apple_Terminal, or app name
#   TAB_ID:       Terminal-specific tab identifier (session ID, TTY path, etc.)

TERM_APP="${1:-}"
TAB_ID="${2:-}"
SESSION_ID="${3:-}"

# Clear persistent notification marker (user clicked the notification directly)
[ -n "$SESSION_ID" ] && rm -f "$HOME/.claude/.persistent-notifications/$SESSION_ID" 2>/dev/null

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
      # Raise the window whose title contains the workspace name, then focus terminal panel
      osascript -e "
        tell application \"$TERM_APP\" to activate
        tell application \"System Events\"
          tell process \"$TERM_APP\"
            repeat with w in windows
              if name of w contains \"$TAB_ID\" then
                perform action \"AXRaise\" of w
                exit repeat
              end if
            end repeat
            -- Focus terminal panel (Ctrl+backtick = default Toggle Terminal keybinding)
            delay 0.2
            keystroke \"\`\" using {control down}
          end tell
        end tell
      " 2>/dev/null
    else
      open -a "$TERM_APP" 2>/dev/null || true
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
