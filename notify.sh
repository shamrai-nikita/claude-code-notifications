#!/bin/bash
# Claude Code notification handler
# Uses a single ClaudeNotifications app bundle (alert style) for branded notifications
# "Temporary" style is simulated via background dismiss timer (sleep + -remove)
# Clicking the notification activates the terminal and switches to the correct tab
# Config: ~/.claude/notify-config.json

NOTIFIER="$HOME/.claude/ClaudeNotifications.app/Contents/MacOS/terminal-notifier"
SENDER="com.anthropic.claude-code-notifier"
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
  for group in claude-code claude-code-persistent claude-code-banner; do
    for app_name in ClaudeNotifications "ClaudeNotifications Alerts" "ClaudeNotifications Banners" ClaudeNotifierPersistent ClaudeNotifierBanner ClaudeNotifier; do
      local notifier="$CLAUDE_DIR/${app_name}.app/Contents/MacOS/terminal-notifier"
      if [ -x "$notifier" ]; then
        "$notifier" -remove "$group" 2>/dev/null || true
      fi
    done
  done

  # 3. Kill background dismiss timer processes
  if [ -d "$CLAUDE_DIR/.persistent-notifications" ]; then
    for dpid_file in "$CLAUDE_DIR/.persistent-notifications"/*.dpid; do
      [ -f "$dpid_file" ] && kill "$(cat "$dpid_file")" 2>/dev/null || true
    done
  fi

  # 4. Unregister app bundles from LaunchServices
  for dir in "$CLAUDE_DIR/ClaudeNotifications.app" "$CLAUDE_DIR/ClaudeNotifications Alerts.app" "$CLAUDE_DIR/ClaudeNotifications Banners.app" "$CLAUDE_DIR/ClaudeNotifierPersistent.app" "$CLAUDE_DIR/ClaudeNotifierBanner.app" "$CLAUDE_DIR/ClaudeNotifier.app"; do
    if [ -d "$dir" ]; then
      "$LSREGISTER" -u "$dir" 2>/dev/null || true
    fi
  done

  # 5. Delete notification files
  rm -f "$CLAUDE_DIR/notify-click.sh" 2>/dev/null
  rm -f "$CLAUDE_DIR/notify-config.json" 2>/dev/null
  rm -f "$CLAUDE_DIR/config-ui.py" 2>/dev/null
  rm -f "$CLAUDE_DIR/Claude.icns" 2>/dev/null
  rm -f "$CLAUDE_DIR/claude-icon-large.png" 2>/dev/null
  rm -f "$CLAUDE_DIR/Configure Notifications.command" 2>/dev/null
  rm -f "$CLAUDE_DIR/.notify-installed" 2>/dev/null
  rm -rf "$CLAUDE_DIR/.persistent-notifications" 2>/dev/null

  # 6. Delete app bundles (new + old names for backward compat)
  rm -rf "$CLAUDE_DIR/ClaudeNotifications.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifications Alerts.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifications Banners.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifierPersistent.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifierBanner.app" 2>/dev/null
  rm -rf "$CLAUDE_DIR/ClaudeNotifier.app" 2>/dev/null

  # 7b. Remove VS Code extension from extensions directories
  for _ext_dir in "$HOME/.cursor/extensions" "$HOME/.vscode/extensions" "$HOME/.vscode-oss/extensions"; do
    rm -rf "$_ext_dir"/anthropic.claude-code-notifications-* 2>/dev/null || true
    # Remove stale entry from editor's extensions.json registry
    if [ -f "$_ext_dir/extensions.json" ]; then
      python3 -c "
import json, sys
path = sys.argv[1]
with open(path) as f:
    exts = json.load(f)
filtered = [e for e in exts if e.get('identifier', {}).get('id') != 'anthropic.claude-code-notifications']
if len(filtered) != len(exts):
    with open(path, 'w') as f:
        json.dump(filtered, f, indent='\t')
        f.write('\n')
" "$_ext_dir/extensions.json" 2>/dev/null || true
    fi
  done

  # 7c. Remove JetBrains plugin from all IDE config directories
  JB_SUPPORT="$HOME/Library/Application Support/JetBrains"
  if [ -d "$JB_SUPPORT" ]; then
    for jb_dir in "$JB_SUPPORT"/*/plugins/claude-code-notifications; do
      [ -d "$jb_dir" ] && rm -rf "$jb_dir"
    done
  fi
  rm -rf "$CLAUDE_DIR/.jb-notify" 2>/dev/null

  # 7. Clean Notification Center database entries
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

  # 8. Delete notify.sh itself — safe because bash holds the fd open
  rm -f "$CLAUDE_DIR/notify.sh" 2>/dev/null
}

INPUT=$(cat)

# If the launcher app was dragged to Trash, clean up everything and exit
if [ ! -d "/Applications/ClaudeNotifications.app" ] && [ -f "$HOME/.claude/.notify-installed" ]; then
  _claude_notify_cleanup
  exit 0
fi

# --- Auto-dismiss: resolve stale notifications ---
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
        # Kill background dismiss timer if running
        if [ -f "$MARKER_DIR/$SID.dpid" ]; then
          kill "$(cat "$MARKER_DIR/$SID.dpid")" 2>/dev/null || true
          rm -f "$MARKER_DIR/$SID.dpid"
        fi
      fi
    fi
    # Fallback: try stable process ID (handles context-clear case where session_id changed)
    if [ -z "$DISMISS_GROUP" ] && [ -n "$STABLE_PID" ] && [ -f "$MARKER_DIR/pid-$STABLE_PID" ]; then
      DISMISS_GROUP=$(cat "$MARKER_DIR/pid-$STABLE_PID")
      # Kill background dismiss timer if running
      if [ -f "$MARKER_DIR/pid-$STABLE_PID.dpid" ]; then
        kill "$(cat "$MARKER_DIR/pid-$STABLE_PID.dpid")" 2>/dev/null || true
        rm -f "$MARKER_DIR/pid-$STABLE_PID.dpid"
      fi
    fi
    # Always clean up the pid marker for this instance
    [ -n "$STABLE_PID" ] && rm -f "$MARKER_DIR/pid-$STABLE_PID"
    # Dismiss the notification
    if [ -n "$DISMISS_GROUP" ]; then
      [ -x "$NOTIFIER" ] && "$NOTIFIER" -remove "$DISMISS_GROUP" 2>/dev/null
      # Legacy fallback
      for legacy in "$HOME/.claude/ClaudeNotifications Alerts.app/Contents/MacOS/terminal-notifier" \
                     "$HOME/.claude/ClaudeNotifierPersistent.app/Contents/MacOS/terminal-notifier" \
                     "$HOME/.claude/ClaudeNotifier.app/Contents/MacOS/terminal-notifier"; do
        [ -x "$legacy" ] && "$legacy" -remove "claude-code" 2>/dev/null
      done
    fi
  fi
  exit 0
fi

# Parse hook event data and read config in a single python3 call
# Outputs: EVENT_KEY ENABLED SOUND VOLUME STYLE SOUND_ENABLED TIMEOUT TITLE BODY SESSION_ID
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
known_event = True
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
    known_event = False
    event_key = event.lower() if event else 'unknown'
    title = 'Claude Code'
    body = message or 'Event occurred'

# Check global kill switch
if not config.get('global_enabled', True) or not known_event:
    enabled = False
    sound = 'Funk'; volume = 4; style = 'banner'; sound_enabled = True; timeout = 5
else:
    # Get per-event config
    evt = events_config.get(event_key, {})
    enabled = evt.get('enabled', event_key in events_config)
    sound = evt.get('sound', 'Funk')
    volume = evt.get('volume', 4)
    style = evt.get('style', 'banner')
    sound_enabled = evt.get('sound_enabled', True)
    timeout = evt.get('timeout', config.get('default_timeout', 5))

# Escape single quotes for shell
title = title.replace(\"'\", \"'\\\\''\")
body = body.replace(\"'\", \"'\\\\''\")

print(f\"EVENT_KEY='{event_key}'\")
print(f\"ENABLED={'1' if enabled else '0'}\")
print(f\"SOUND='{sound}'\")
print(f\"VOLUME={volume / 10.0}\")
print(f\"STYLE='{style}'\")
print(f\"SOUND_ENABLED={'1' if sound_enabled else '0'}\")
print(f\"TIMEOUT={timeout}\")
print(f\"TITLE='{title}'\")
print(f\"BODY='{body}'\")
print(f\"SESSION_ID='{session_id}'\")
" 2>/dev/null)

# Guard: if Python failed, ENABLED was never set — exit silently
if [ -z "${ENABLED+x}" ]; then
  exit 0
fi

# Exit if this event is disabled
if [ "$ENABLED" = "0" ]; then
  exit 0
fi

# --- Warp: use native OSC 777 notifications ---
# Warp supports OSC 777 escape sequences for notifications. The escape sequence
# must reach the Warp tab's PTY so Warp can handle click-to-focus natively.
# Hook subprocesses may lack a controlling terminal (/dev/tty fails), so we
# walk the process tree to find the actual TTY device from an ancestor process.
# Reference: https://github.com/warpdotdev/claude-code-warp
if [ "${TERM_PROGRAM:-}" = "WarpTerminal" ]; then
  # Find the actual TTY device from our process hierarchy
  WARP_TTY=""
  _pid=$$
  while [ "$_pid" -gt 1 ] 2>/dev/null; do
    _tty=$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')
    if [ -n "$_tty" ] && [ "$_tty" != "??" ]; then
      WARP_TTY="/dev/$_tty"
      break
    fi
    _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
  done
  if [ -n "$WARP_TTY" ] && [ -w "$WARP_TTY" ]; then
    printf '\033]777;notify;%s;%s\007' "$TITLE" "$BODY" > "$WARP_TTY" 2>/dev/null || true
  fi
  # No afplay — Warp plays its own notification sound for OSC 777
  exit 0
fi

# Single notifier app — group is per-session
GROUP="claude-code"
if [ -n "$SESSION_ID" ]; then
  GROUP="${GROUP}-${SESSION_ID}"
fi

# Fallback: try legacy app bundles if new single app doesn't exist
if [ ! -x "$NOTIFIER" ]; then
  for fallback in "$HOME/.claude/ClaudeNotifications Alerts.app/Contents/MacOS/terminal-notifier" \
                   "$HOME/.claude/ClaudeNotifierPersistent.app/Contents/MacOS/terminal-notifier" \
                   "$HOME/.claude/ClaudeNotifier.app/Contents/MacOS/terminal-notifier"; do
    if [ -x "$fallback" ]; then
      NOTIFIER="$fallback"
      break
    fi
  done
fi

# Auto-detect terminal and tab identifier from environment
TERM_APP="${TERM_PROGRAM:-}"

# JetBrains IDE: detect via plugin env vars (specific) or TERMINAL_EMULATOR (generic)
if [ -n "${CLAUDE_JB_NOTIFY_PORT:-}" ]; then
  # Plugin installed: full tab-switching support
  TERM_APP="JetBrains"
  TAB_ID="${CLAUDE_JB_TAB_ID:-}|${CLAUDE_JB_NOTIFY_PORT}|${CLAUDE_JB_IDE_PID:-}"
elif [ "${TERMINAL_EMULATOR:-}" = "JetBrains-JediTerm" ]; then
  # JetBrains terminal without plugin: app-level activation only
  TERM_APP="JetBrains"
  TAB_ID=""
fi

case "$TERM_APP" in
  JetBrains)      ;; # Already handled above
  WarpTerminal)   TAB_ID="" ;;
  iTerm.app)      TAB_ID="${ITERM_SESSION_ID:-}" ;;
  Apple_Terminal)  TAB_ID="/dev/$(ps -o tty= -p $PPID 2>/dev/null | xargs)" ;;
  vscode)
    # Detect actual app by walking process tree to find .app bundle.
    # Collect ancestor PIDs along the way — one of them will match
    # terminal.processId in the VS Code extension for tab switching.
    _pid=$PPID
    _ancestor_pids=""
    while [ "$_pid" -gt 1 ] 2>/dev/null; do
      _ancestor_pids="${_ancestor_pids:+${_ancestor_pids},}${_pid}"
      _args=$(ps -o args= -p $_pid 2>/dev/null)
      case "$_args" in
        */Cursor.app/*)                TERM_APP="Cursor"; break ;;
        */"Visual Studio Code"*.app/*) TERM_APP="Visual Studio Code"; break ;;
        */VSCodium.app/*)              TERM_APP="VSCodium"; break ;;
      esac
      _pid=$(ps -o ppid= -p $_pid 2>/dev/null | tr -d ' ')
    done
    TAB_ID="$_ancestor_pids"
    ;;
  *)              TAB_ID="" ;;
esac

# Dismiss this session's previous notification (if any)
if [ -n "$SESSION_ID" ] && [ -f "$MARKER_DIR/$SESSION_ID" ]; then
  OLD_GROUP=$(cat "$MARKER_DIR/$SESSION_ID")
  rm -f "$MARKER_DIR/$SESSION_ID"
  [ -n "$STABLE_PID" ] && rm -f "$MARKER_DIR/pid-$STABLE_PID"
  # Kill old background dismiss timer
  if [ -f "$MARKER_DIR/$SESSION_ID.dpid" ]; then
    kill "$(cat "$MARKER_DIR/$SESSION_ID.dpid")" 2>/dev/null || true
    rm -f "$MARKER_DIR/$SESSION_ID.dpid"
  fi
  if [ -n "$STABLE_PID" ] && [ -f "$MARKER_DIR/pid-$STABLE_PID.dpid" ]; then
    kill "$(cat "$MARKER_DIR/pid-$STABLE_PID.dpid")" 2>/dev/null || true
    rm -f "$MARKER_DIR/pid-$STABLE_PID.dpid"
  fi
  [ -x "$NOTIFIER" ] && "$NOTIFIER" -remove "$OLD_GROUP" 2>/dev/null
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

# Track active notification for auto-dismiss (all styles, not just persistent)
if [ -n "$SESSION_ID" ]; then
  mkdir -p "$MARKER_DIR"
  echo "$GROUP" > "$MARKER_DIR/$SESSION_ID"
  [ -n "$STABLE_PID" ] && echo "$GROUP" > "$MARKER_DIR/pid-$STABLE_PID"
fi

# For temporary (banner) style: spawn background dismiss timer
if [ "$STYLE" = "banner" ] && [ -n "$SESSION_ID" ]; then
  (
    sleep "$TIMEOUT"
    "$NOTIFIER" -remove "$GROUP" 2>/dev/null
    rm -f "$MARKER_DIR/$SESSION_ID" 2>/dev/null
    rm -f "$MARKER_DIR/$SESSION_ID.dpid" 2>/dev/null
    [ -n "$STABLE_PID" ] && rm -f "$MARKER_DIR/pid-$STABLE_PID" 2>/dev/null
    [ -n "$STABLE_PID" ] && rm -f "$MARKER_DIR/pid-$STABLE_PID.dpid" 2>/dev/null
  ) &
  DISMISS_PID=$!
  echo "$DISMISS_PID" > "$MARKER_DIR/$SESSION_ID.dpid"
  [ -n "$STABLE_PID" ] && echo "$DISMISS_PID" > "$MARKER_DIR/pid-$STABLE_PID.dpid"
fi

# Play alert sound at configured volume (if sound is enabled)
if [ "$SOUND_ENABLED" = "1" ]; then
  afplay "/System/Library/Sounds/${SOUND}.aiff" -v "$VOLUME" &
fi
