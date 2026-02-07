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

INPUT=$(cat)

# Parse hook event data and read config in a single python3 call
# Outputs: EVENT_KEY ENABLED SOUND VOLUME STYLE SOUND_ENABLED TITLE BODY
eval $(CLAUDE_HOOK_INPUT="$INPUT" python3 -c "
import sys, json, os

raw = os.environ.get('CLAUDE_HOOK_INPUT', ''); hook = json.loads(raw) if raw.strip() else {}
event = hook.get('hook_event_name', '')
message = hook.get('message', '')
notif_type = hook.get('notification_type', '')
tool_name = hook.get('tool_name', '')

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
" 2>/dev/null)

# Exit if this event is disabled
if [ "$ENABLED" = "0" ]; then
  exit 0
fi

# Select notifier app and group based on style
if [ "$STYLE" = "banner" ]; then
  NOTIFIER="$NOTIFIER_BANNER"
  GROUP="claude-code-banner"
else
  NOTIFIER="$NOTIFIER_PERSISTENT"
  GROUP="claude-code-persistent"
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

# Send notification — clicking it activates the terminal and switches to the correct tab
if [ -n "$TERM_APP" ]; then
  "$NOTIFIER" \
    -title "$TITLE" \
    -message "$BODY" \
    -execute "bash $HOME/.claude/notify-click.sh '$TERM_APP' '$TAB_ID'" \
    -group "$GROUP" \
    2>/dev/null
else
  # Unknown terminal — fall back to generic activation (no tab switching)
  "$NOTIFIER" \
    -title "$TITLE" \
    -message "$BODY" \
    -group "$GROUP" \
    2>/dev/null
fi

# Play alert sound at configured volume (if sound is enabled)
if [ "$SOUND_ENABLED" = "1" ]; then
  afplay "/System/Library/Sounds/${SOUND}.aiff" -v "$VOLUME" &
fi
