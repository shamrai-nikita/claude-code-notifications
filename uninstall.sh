#!/bin/bash
# Claude Code Notifications — macOS uninstaller
# Removes all notification components from ~/.claude/
set -e

CLAUDE_DIR="$HOME/.claude"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

FILES_TO_REMOVE=(
  "$CLAUDE_DIR/notify.sh"
  "$CLAUDE_DIR/notify-click.sh"
  "$CLAUDE_DIR/notify-config.json"
  "$CLAUDE_DIR/config-ui.py"
  "$CLAUDE_DIR/Claude.icns"
  "$CLAUDE_DIR/claude-icon-large.png"
  "$CLAUDE_DIR/Configure Notifications.command"
)
DIRS_TO_REMOVE=(
  "$CLAUDE_DIR/ClaudeNotifierPersistent.app"
  "$CLAUDE_DIR/ClaudeNotifierBanner.app"
  "$CLAUDE_DIR/ClaudeNotifier.app"
)

echo "=== Claude Code Notifications Uninstaller ==="
echo ""
echo "This will remove:"
echo "  - Notification hooks from ~/.claude/settings.json"
echo "  - notify.sh, notify-config.json, config-ui.py"
echo "  - ClaudeNotifier*.app bundles"
echo "  - Claude icon files"
echo "  - Configure Notifications.command"
echo "  - Notification Center entries (System Settings > Notifications)"
echo ""
echo "Will NOT remove:"
echo "  - terminal-notifier Homebrew package"
echo "  - ~/.claude/ directory itself"
echo "  - Any other settings in settings.json"
echo ""
read -rp "Proceed? [y/N] " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""
removed=0

# 1. Remove notification hooks from settings.json
SETTINGS="$CLAUDE_DIR/settings.json"
if [ -f "$SETTINGS" ]; then
  echo "Removing hooks from settings.json..."
  python3 -c "
import json, os, sys

path = '$SETTINGS'
with open(path) as f:
    settings = json.load(f)

hooks = settings.get('hooks', {})
changed = False
for event in ['Notification', 'PermissionRequest', 'Stop']:
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
    print('  Hooks removed.')
else:
    print('  No notification hooks found.')
" || echo "  WARNING: Could not update settings.json"
  removed=$((removed + 1))
else
  echo "No settings.json found — skipping hook removal."
fi

# 2. Clear delivered notifications
echo "Clearing delivered notifications..."
for group in claude-code-persistent claude-code-banner claude-code; do
  for variant in Persistent Banner ""; do
    notifier="$CLAUDE_DIR/ClaudeNotifier${variant}.app/Contents/MacOS/terminal-notifier"
    if [ -x "$notifier" ]; then
      "$notifier" -remove "$group" 2>/dev/null || true
    fi
  done
done
echo "  Done."

# 3. Unregister app bundles from LaunchServices
echo "Unregistering app bundles..."
for dir in "${DIRS_TO_REMOVE[@]}"; do
  if [ -d "$dir" ]; then
    "$LSREGISTER" -u "$dir" 2>/dev/null || true
    echo "  Unregistered: $(basename "$dir")"
  fi
done

# 4. Delete files
echo "Removing files..."
for f in "${FILES_TO_REMOVE[@]}"; do
  if [ -f "$f" ]; then
    rm "$f"
    echo "  Removed: $(basename "$f")"
    removed=$((removed + 1))
  fi
done

# 5. Delete app directories
echo "Removing app bundles..."
for dir in "${DIRS_TO_REMOVE[@]}"; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "  Removed: $(basename "$dir")"
    removed=$((removed + 1))
  fi
done

# 6. Remove entries from Notification Center database
# Must kill usernoted BEFORE modifying the DB — it holds the file open and
# will overwrite our changes on restart. After kill, launchd restarts it and
# the new process reads the already-cleaned DB.
NCDB="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
if [ -f "$NCDB" ]; then
  echo "Removing Notification Center entries..."
  nc_removed=$(sqlite3 "$NCDB" "SELECT COUNT(*) FROM app WHERE identifier LIKE 'com.anthropic.claude-code-notifier%';" 2>/dev/null || echo "0")
  if [ "$nc_removed" -gt 0 ]; then
    killall usernoted 2>/dev/null || true
    sleep 0.5
    sqlite3 "$NCDB" "DELETE FROM app WHERE identifier LIKE 'com.anthropic.claude-code-notifier%';" 2>/dev/null || true
    # Kill System Settings and NotificationCenter so they re-read the cleaned DB
    osascript -e 'tell application id "com.apple.systempreferences" to quit' 2>/dev/null || true
    killall NotificationCenter 2>/dev/null || true
    echo "  Removed $nc_removed entries from Notification Center."
    removed=$((removed + nc_removed))
  else
    echo "  No Notification Center entries found."
  fi
fi

echo ""
if [ "$removed" -gt 0 ]; then
  echo "=== Uninstall complete ($removed items removed) ==="
else
  echo "=== Already clean — nothing to remove ==="
fi
echo ""
echo "Note: terminal-notifier Homebrew package was NOT removed."
echo "  To remove it: brew uninstall terminal-notifier"
