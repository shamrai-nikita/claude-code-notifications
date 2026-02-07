#!/bin/bash
# Claude Code notification handler
# Uses custom ClaudeNotifier apps for branded notifications
# Persistent and Banner variants for per-event alert style
# Clicking the notification opens Warp terminal
# Config: ~/.claude/notify-config.json

NOTIFIER_PERSISTENT="$HOME/.claude/ClaudeNotifierPersistent.app/Contents/MacOS/terminal-notifier"
NOTIFIER_BANNER="$HOME/.claude/ClaudeNotifierBanner.app/Contents/MacOS/terminal-notifier"
NOTIFIER_LEGACY="$HOME/.claude/ClaudeNotifier.app/Contents/MacOS/terminal-notifier"
TERMINAL_BUNDLE="dev.warp.Warp-Stable"
CONFIG="$HOME/.claude/notify-config.json"

INPUT=$(cat)

# Parse hook event data and read config in a single python3 call
# Outputs: EVENT_KEY ENABLED SOUND VOLUME STYLE TITLE BODY
eval $(python3 -c "
import sys, json, os

hook = json.loads('''$INPUT''') if '''$INPUT'''.strip() else {}
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

default_sound = config.get('default_sound', 'Funk')
default_volume = config.get('default_volume', 10)
default_style = config.get('default_style', 'persistent')
events_config = config.get('events', {})

# Determine event key and notification text
if event == 'PermissionRequest':
    event_key = 'permission_request'
    title = 'Claude Code - Permission Required'
    body = f'Approve: {tool_name}' if tool_name else 'Permission required'
elif event == 'Notification':
    event_key = notif_type if notif_type else 'notification'
    titles = {
        'permission_prompt': 'Claude Code - Action Required',
        'idle_prompt': 'Claude Code - Action Required',
        'elicitation_dialog': 'Claude Code - Action Required',
    }
    title = titles.get(notif_type, 'Claude Code - Action Required')
    bodies = {
        'permission_prompt': f'Permission required: {message}' if message else 'Permission required',
        'idle_prompt': f'Waiting for your input: {message}' if message else 'Waiting for your input',
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

# Get per-event config
evt = events_config.get(event_key, {})
enabled = evt.get('enabled', True)
sound = evt.get('sound', default_sound)
volume = evt.get('volume', default_volume)
style = evt.get('style', default_style)

# Escape single quotes for shell
title = title.replace(\"'\", \"'\\\\''\")
body = body.replace(\"'\", \"'\\\\''\")

print(f\"EVENT_KEY='{event_key}'\")
print(f\"ENABLED={'1' if enabled else '0'}\")
print(f\"SOUND='{sound}'\")
print(f\"VOLUME={volume}\")
print(f\"STYLE='{style}'\")
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

# Send notification — clicking it opens Warp
"$NOTIFIER" \
  -title "$TITLE" \
  -message "$BODY" \
  -activate "$TERMINAL_BUNDLE" \
  -group "$GROUP" \
  2>/dev/null

# Play alert sound at configured volume
afplay "/System/Library/Sounds/${SOUND}.aiff" -v "$VOLUME" &
