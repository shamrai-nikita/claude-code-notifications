#!/bin/bash
# Claude Code notification handler
# Uses custom ClaudeNotifier apps for branded notifications
# Persistent and Banner variants for per-event alert style
# Clicking the notification activates the terminal and switches to the correct tab
# Config: ~/.claude/notify-config.json

NOTIFIER_PERSISTENT="$HOME/.claude/ClaudeNotifierPersistent.app/Contents/MacOS/terminal-notifier"
NOTIFIER_BANNER="$HOME/.claude/ClaudeNotifierBanner.app/Contents/MacOS/terminal-notifier"
NOTIFIER_LEGACY="$HOME/.claude/ClaudeNotifier.app/Contents/MacOS/terminal-notifier"
CONFIG="$HOME/.claude/notify-config.json"

# --- Trash-based uninstall cleanup ---
# If ClaudeNotifications.app was dragged to Trash, perform full cleanup and exit.
# Uses a directory-based lock (mkdir is atomic) to prevent concurrent cleanup
# from multiple hook events firing simultaneously.
_claude_notify_cleanup() {
  local CLAUDE_DIR="$HOME/.claude"
  local SETTINGS="$CLAUDE_DIR/settings.json"
  local LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

  # Acquire lock — another cleanup may already be running
  local LOCKFILE="$CLAUDE_DIR/.notify-uninstall.lock"
  if ! mkdir "$LOCKFILE" 2>/dev/null; then
    return 0
  fi
  trap 'rmdir "$LOCKFILE" 2>/dev/null' EXIT

  # 1. Remove notification hooks from settings.json
  if [ -f "$SETTINGS" ]; then
    python3 -c "
import json, os
path = '$SETTINGS'
with open(path) as f:
    settings = json.load(f)
hooks = settings.get('hooks', {})
changed = False
for event in ['Notification', 'PermissionRequest', 'Stop', 'PostToolUse', 'UserPromptSubmit']:
    if event in hooks:
        filtered = [
            entry for entry in hooks[event]
            if not any(
                'notify.sh' in h.get('command', '')
                for h in entry.get('hooks', [])
            )
        ]
        if len(filtered) != len(hooks[event]):
            changed = True
        if filtered:
            hooks[event] = filtered
        else:
            del hooks[event]
if not hooks and 'hooks' in settings:
    del settings['hooks']
else:
    settings['hooks'] = hooks
if changed:
    with open(path, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
" 2>/dev/null || true
  fi

  # 2. Clear delivered notifications
  for group in claude-code-persistent claude-code-banner claude-code; do
    for variant in Persistent Banner ""; do
      local notifier="$CLAUDE_DIR/ClaudeNotifier${variant}.app/Contents/MacOS/terminal-notifier"
      if [ -x "$notifier" ]; then
        "$notifier" -remove "$group" 2>/dev/null || true
      fi
    done
  done

  # 3. Unregister app bundles from LaunchServices
  for dir in "$CLAUDE_DIR/ClaudeNotifierPersistent.app" "$CLAUDE_DIR/ClaudeNotifierBanner.app" "$CLAUDE_DIR/ClaudeNotifier.app"; do
    if [ -d "$dir" ]; then
      "$LSREGISTER" -u "$dir" 2>/dev/null || true
    fi
  done

  # 4. Delete notification files
  rm -f "$CLAUDE_DIR/notify-click.sh" 2>/dev/null
  rm -f "$CLAUDE_DIR/notify-config.json" 2>/dev/null
  rm -f "$CLAUDE_DIR/config-ui.py" 2>/dev/null
  rm -f "$CLAUDE_DIR/Claude.icns" 2>/dev/null
  rm -f "$CLAUDE_DIR/claude-icon-large.png" 2>/dev/null
  rm -f "$CLAUDE_DIR/Configure Notifications.command" 2>/dev/null
  rm -f "$CLAUDE_DIR/.notify-installed" 2>/dev/null
  rm -rf "$CLAUDE_DIR/.persistent-notifications" 2>/dev/null

  # 5. Delete app bundles
  rm -rf "$CLAUDE_DIR/ClaudeNotifierPersistent.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifierBanner.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifier.app" 2>/dev/null

  # 6. Clean Notification Center database entries
  local NCDB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
  if [ -f "$NCDB" ]; then
    local nc_count
    nc_count=$(sqlite3 "$NCDB" "SELECT COUNT(*) FROM app WHERE identifier LIKE 'com.anthropic.claude-code-notifier%';" 2>/dev/null || echo "0")
    if [ "$nc_count" -gt 0 ]; then
      killall usernoted 2>/dev/null || true
      sleep 0.5
      sqlite3 "$NCDB" "DELETE FROM app WHERE identifier LIKE 'com.anthropic.claude-code-notifier%';" 2>/dev/null || true
      killall NotificationCenter 2>/dev/null || true
    fi
  fi

  # 7. Delete notify.sh itself — safe because bash holds the fd open
  rm -f "$CLAUDE_DIR/notify.sh" 2>/dev/null
}

INPUT=$(cat)

# If the launcher app was dragged to Trash, clean up everything and exit
if [ ! -d "/Applications/ClaudeNotifications.app" ] && [ -f "$HOME/.claude/.notify-installed" ]; then
  _claude_notify_cleanup
  exit 0
fi

# --- Auto-dismiss: resolve stale persistent notifications ---
# PostToolUse = permission was granted and tool ran. UserPromptSubmit = user responded.
MARKER_DIR="$HOME/.claude/.persistent-notifications"
# Stable process ID: grandparent PID persists across context clears within the same
# Claude Code instance, but differs between terminals (no cross-session interference).
STABLE_PID=$(ps -o ppid= -p $PPID 2>/dev/null | tr -d ' ')
if [[ "$INPUT" == *'"PostToolUse"'* ]] || [[ "$INPUT" == *'"UserPromptSubmit"'* ]]; then
  if [ -d "$MARKER_DIR" ]; then
    # Try session_id match first (normal case)
    DISMISS_GROUP=""
    if [[ "$INPUT" =~ \"session_id\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
      SID="${BASH_REMATCH[1]}"
      if [ -f "$MARKER_DIR/$SID" ]; then
        DISMISS_GROUP=$(cat "$MARKER_DIR/$SID")
        rm -f "$MARKER_DIR/$SID"
      fi
    fi
    # Fallback: try stable process ID (handles context-clear case where session_id changed)
    if [ -z "$DISMISS_GROUP" ] && [ -n "$STABLE_PID" ] && [ -f "$MARKER_DIR/pid-$STABLE_PID" ]; then
      DISMISS_GROUP=$(cat "$MARKER_DIR/pid-$STABLE_PID")
    fi
    # Always clean up the pid marker for this instance
    [ -n "$STABLE_PID" ] && rm -f "$MARKER_DIR/pid-$STABLE_PID"
    # Dismiss the notification
    if [ -n "$DISMISS_GROUP" ]; then
      [ -x "$NOTIFIER_PERSISTENT" ] && "$NOTIFIER_PERSISTENT" -remove "$DISMISS_GROUP" 2>/dev/null
      [ -x "$NOTIFIER_LEGACY" ] && "$NOTIFIER_LEGACY" -remove "claude-code" 2>/dev/null
    fi
  fi
  exit 0
fi

# Parse hook event data and read config in a single python3 call
# Outputs: EVENT_KEY ENABLED SOUND VOLUME STYLE SOUND_ENABLED TITLE BODY SESSION_ID
eval $(CLAUDE_HOOK_INPUT="$INPUT" python3 -c "
import sys, json, os

raw = os.environ.get('CLAUDE_HOOK_INPUT', ''); hook = json.loads(raw) if raw.strip() else {}
event = hook.get('hook_event_name', '')
message = hook.get('message', '')
notif_type = hook.get('notification_type', '')
tool_name = hook.get('tool_name', '')
session_id = hook.get('session_id', '')

# Load config
config_path = os.path.expanduser('$CONFIG')
try:
    with open(config_path) as f:
        config = json.load(f)
except:
    config = {}

events_config = config.get('events', {})

# Determine event key and notification text
if event == 'PermissionRequest':
    event_key = 'permission_request'
    title = 'Claude Code - Permission Required'
    body = f'Approve: {tool_name}' if tool_name else 'Permission required'
elif event == 'Notification':
    event_key = notif_type if notif_type else 'notification'
    titles = {
        'elicitation_dialog': 'Claude Code - Action Required',
    }
    title = titles.get(notif_type, 'Claude Code - Action Required')
    bodies = {
        'elicitation_dialog': f'Claude has a question: {message}' if message else 'Claude has a question',
    }
    body = bodies.get(notif_type, message or 'Needs your attention')
elif event == 'Stop':
    event_key = 'stop'
    title = 'Claude Code - Done'
    body = 'Finished responding'
else:
    event_key = event.lower() if event else 'unknown'
    title = 'Claude Code'
    body = message or 'Event occurred'

# Check global kill switch
if not config.get('global_enabled', True):
    enabled = False
    sound = 'Funk'; volume = 7; style = 'persistent'; sound_enabled = True
else:
    # Get per-event config
    evt = events_config.get(event_key, {})
    enabled = evt.get('enabled', event_key in events_config)
    sound = evt.get('sound', 'Funk')
    volume = evt.get('volume', 7)
    style = evt.get('style', 'persistent')
    sound_enabled = evt.get('sound_enabled', True)

# Escape single quotes for shell
title = title.replace(\"'\", \"'\\\\''\")
body = body.replace(\"'\", \"'\\\\''\")

print(f\"EVENT_KEY='{event_key}'\")
print(f\"ENABLED={'1' if enabled else '0'}\")
print(f\"SOUND='{sound}'\")
print(f\"VOLUME={volume}\")
print(f\"STYLE='{style}'\")
print(f\"SOUND_ENABLED={'1' if sound_enabled else '0'}\")
print(f\"TITLE='{title}'\")
print(f\"BODY='{body}'\")
print(f\"SESSION_ID='{session_id}'\")
" 2>/dev/null)

# Exit if this event is disabled
if [ "$ENABLED" = "0" ]; then
  exit 0
fi

# Select notifier app and group based on style
if [ "$STYLE" = "banner" ]; then
  NOTIFIER="$NOTIFIER_BANNER"
  GROUP="claude-code-banner"
  SENDER="com.anthropic.claude-code-notifier-banner"
else
  NOTIFIER="$NOTIFIER_PERSISTENT"
  GROUP="claude-code-persistent"
  SENDER="com.anthropic.claude-code-notifier-persistent"
fi

# Per-session group for independent multi-session notifications
if [ -n "$SESSION_ID" ]; then
  GROUP="${GROUP}-${SESSION_ID}"
fi

# Fallback: try legacy ClaudeNotifier.app if selected variant doesn't exist
if [ ! -x "$NOTIFIER" ]; then
  if [ -x "$NOTIFIER_LEGACY" ]; then
    NOTIFIER="$NOTIFIER_LEGACY"
    GROUP="claude-code"
  fi
fi

# Auto-detect terminal and tab identifier from environment
TERM_APP="${TERM_PROGRAM:-}"
case "$TERM_APP" in
  WarpTerminal)   TAB_ID="" ;;
  iTerm.app)      TAB_ID="${ITERM_SESSION_ID:-}" ;;
  Apple_Terminal)  TAB_ID="/dev/$(ps -o tty= -p $PPID 2>/dev/null | xargs)" ;;
  *)              TAB_ID="" ;;
esac

# Dismiss this session's previous persistent notification (if any)
if [ -n "$SESSION_ID" ] && [ -f "$MARKER_DIR/$SESSION_ID" ]; then
  OLD_GROUP=$(cat "$MARKER_DIR/$SESSION_ID")
  rm -f "$MARKER_DIR/$SESSION_ID"
  [ -n "$STABLE_PID" ] && rm -f "$MARKER_DIR/pid-$STABLE_PID"
  [ -x "$NOTIFIER_PERSISTENT" ] && "$NOTIFIER_PERSISTENT" -remove "$OLD_GROUP" 2>/dev/null
  [ -x "$NOTIFIER_LEGACY" ] && "$NOTIFIER_LEGACY" -remove "claude-code" 2>/dev/null
fi

# Send notification — clicking it activates the terminal and switches to the correct tab
# -sender forces macOS to use our app's icon (same binary UUID as original terminal-notifier)
if [ -n "$TERM_APP" ]; then
  "$NOTIFIER" \
    -title "$TITLE" \
    -message "$BODY" \
    -sender "$SENDER" \
    -execute "bash $HOME/.claude/notify-click.sh '$TERM_APP' '$TAB_ID' '$SESSION_ID'" \
    -group "$GROUP" \
    2>/dev/null
else
  # Unknown terminal — fall back to generic activation (no tab switching)
  "$NOTIFIER" \
    -title "$TITLE" \
    -message "$BODY" \
    -sender "$SENDER" \
    -group "$GROUP" \
    2>/dev/null
fi

# Track active persistent notification for auto-dismiss
if [ "$STYLE" != "banner" ] && [ -n "$SESSION_ID" ]; then
  mkdir -p "$MARKER_DIR"
  echo "$GROUP" > "$MARKER_DIR/$SESSION_ID"
  [ -n "$STABLE_PID" ] && echo "$GROUP" > "$MARKER_DIR/pid-$STABLE_PID"
fi

# Play alert sound at configured volume (if sound is enabled)
if [ "$SOUND_ENABLED" = "1" ]; then
  afplay "/System/Library/Sounds/${SOUND}.aiff" -v "$VOLUME" &
fi
