#!/bin/bash
# Claude Code Notifications — macOS installer
# Installs notification system to ~/.claude/
set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

echo "=== Claude Code Notifications Installer ==="

# 1. Check/install terminal-notifier
if ! command -v terminal-notifier &>/dev/null; then
  echo "Installing terminal-notifier via Homebrew..."
  brew install terminal-notifier
else
  echo "terminal-notifier already installed."
fi

TN_APP=$(find /usr/local/Cellar/terminal-notifier -name "terminal-notifier.app" -maxdepth 2 2>/dev/null | head -1)
if [ -z "$TN_APP" ]; then
  TN_APP=$(find /opt/homebrew/Cellar/terminal-notifier -name "terminal-notifier.app" -maxdepth 2 2>/dev/null | head -1)
fi
if [ -z "$TN_APP" ]; then
  echo "ERROR: Could not find terminal-notifier.app in Homebrew cellar."
  exit 1
fi
echo "Found terminal-notifier at: $TN_APP"

# 2. Copy icon from repo and convert to PNG (source may be JPEG despite .png extension)
echo "Installing icon..."
sips -s format png "$SCRIPT_DIR/icon.png" --out "$CLAUDE_DIR/claude-icon-large.png" > /dev/null

# 3. Convert to icns
echo "Converting icon to icns..."
ICONSET="$CLAUDE_DIR/claude.iconset"
mkdir -p "$ICONSET"
SRC="$CLAUDE_DIR/claude-icon-large.png"
sips -s format png -z 16 16 "$SRC" --out "$ICONSET/icon_16x16.png" > /dev/null
sips -s format png -z 32 32 "$SRC" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
sips -s format png -z 32 32 "$SRC" --out "$ICONSET/icon_32x32.png" > /dev/null
sips -s format png -z 64 64 "$SRC" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
sips -s format png -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png" > /dev/null
sips -s format png -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
sips -s format png -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png" > /dev/null
sips -s format png -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
sips -s format png -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png" > /dev/null
sips -s format png -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
iconutil -c icns "$ICONSET" -o "$CLAUDE_DIR/Claude.icns"
rm -rf "$ICONSET"
echo "Icon created."

# 4. Build ClaudeNotifier app bundles (Persistent + Banner)
echo "Building ClaudeNotifier app bundles..."

# Remove legacy single-variant app if present
if [ -d "$CLAUDE_DIR/ClaudeNotifier.app" ]; then
  echo "Removing legacy ClaudeNotifier.app..."
  rm -rf "$CLAUDE_DIR/ClaudeNotifier.app"
fi

for variant in Persistent Banner; do
  APP_NAME="ClaudeNotifier${variant}.app"
  echo "  Building $APP_NAME..."
  rm -rf "$CLAUDE_DIR/$APP_NAME"
  cp -R "$TN_APP" "$CLAUDE_DIR/$APP_NAME"
  cp "$SCRIPT_DIR/ClaudeNotifier${variant}.plist" "$CLAUDE_DIR/$APP_NAME/Contents/Info.plist"
  cp "$CLAUDE_DIR/Claude.icns" "$CLAUDE_DIR/$APP_NAME/Contents/Resources/Claude.icns"
  # Re-sign with our bundle ID so macOS treats it as a distinct app (not the original terminal-notifier)
  BUNDLE_ID=$(defaults read "$CLAUDE_DIR/$APP_NAME/Contents/Info.plist" CFBundleIdentifier)
  codesign --force -s - --identifier "$BUNDLE_ID" "$CLAUDE_DIR/$APP_NAME" 2>/dev/null || true
  touch "$CLAUDE_DIR/$APP_NAME"
  $LSREGISTER -f "$CLAUDE_DIR/$APP_NAME"
  echo "  $APP_NAME installed and registered."
done

# 5. Send test notifications to trigger macOS permission prompts
echo "Triggering notification permissions (you may see test notifications)..."
for variant in Persistent Banner; do
  NOTIFIER="$CLAUDE_DIR/ClaudeNotifier${variant}.app/Contents/MacOS/terminal-notifier"
  "$NOTIFIER" -title "Claude Code Setup" -message "Notifications enabled" -group "claude-setup-${variant}" 2>/dev/null || true
done
# Brief pause then remove the test notifications
sleep 1
for variant in Persistent Banner; do
  NOTIFIER="$CLAUDE_DIR/ClaudeNotifier${variant}.app/Contents/MacOS/terminal-notifier"
  "$NOTIFIER" -remove "claude-setup-${variant}" 2>/dev/null || true
done

# 5b. Configure notification alert styles in system preferences
# macOS ignores NSUserNotificationAlertStyle for unsigned apps, so we set it
# directly in com.apple.ncprefs.plist (the Notification Center prefs store).
echo "Configuring notification alert styles..."
sleep 1  # allow ncprefs to register the new apps
python3 -c "
import subprocess, plistlib, sys

result = subprocess.run(['defaults', 'export', 'com.apple.ncprefs', '-'], capture_output=True)
if result.returncode != 0:
    print('  WARNING: Could not read notification preferences. Set alert styles manually.')
    sys.exit(0)

pl = plistlib.loads(result.stdout)
apps = pl.get('apps', [])

BANNERS = 1 << 3       # 8
ALERTS  = 1 << 4       # 16
SHOW_NC = 1 << 0       # 1
BADGE   = 1 << 1       # 2
SOUND   = 1 << 2       # 4
ALLOW   = 1 << 25      # 33554432

targets = {
    'com.anthropic.claude-code-notifier-persistent': ALERTS,
    'com.anthropic.claude-code-notifier-banner': BANNERS,
}
configured = []

for app in apps:
    bid = app.get('bundle-id', '')
    if bid in targets:
        flags = app.get('flags', 0)
        # Clear both style bits, then set the desired one
        flags &= ~(BANNERS | ALERTS)
        flags |= targets[bid]
        flags |= ALLOW | SHOW_NC | BADGE | SOUND
        app['flags'] = flags
        configured.append(bid.split('-')[-1])  # 'persistent' or 'banner'

if configured:
    data = plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)
    wr = subprocess.run(['defaults', 'import', 'com.apple.ncprefs', '-'], input=data)
    if wr.returncode == 0:
        subprocess.run(['killall', 'usernoted'], capture_output=True)
        subprocess.run(['killall', 'NotificationCenter'], capture_output=True)
        print('  Alert styles configured: ' + ', '.join(configured))
    else:
        print('  WARNING: Could not write notification preferences. Set alert styles manually.')
else:
    print('  WARNING: Apps not yet registered in Notification Center. Set alert styles manually:')
    print('    System Settings > Notifications > ClaudeNotifications (Persistent) > Alerts')
    print('    System Settings > Notifications > ClaudeNotifications (Vanishing) > Banners')
" || echo "  WARNING: Could not configure alert styles. Set manually in System Settings > Notifications."

# 6. Copy notify.sh and config
echo "Installing notify.sh and config..."
cp "$SCRIPT_DIR/notify.sh" "$CLAUDE_DIR/notify.sh"
chmod +x "$CLAUDE_DIR/notify.sh"
cp "$SCRIPT_DIR/notify-click.sh" "$CLAUDE_DIR/notify-click.sh"
chmod +x "$CLAUDE_DIR/notify-click.sh"

if [ ! -f "$CLAUDE_DIR/notify-config.json" ]; then
  cp "$SCRIPT_DIR/notify-config.json" "$CLAUDE_DIR/notify-config.json"
  echo "Config installed (fresh)."
else
  echo "Config already exists — skipping (edit ~/.claude/notify-config.json manually)."
fi

# 7. Install config UI
echo "Installing config-ui.py..."
cp "$SCRIPT_DIR/config-ui.py" "$CLAUDE_DIR/config-ui.py"

# 8. Build clickable launcher app (in /Applications/ for Spotlight/Launchpad)
echo "Building ClaudeNotifications.app launcher..."
LAUNCHER_APP="/Applications/ClaudeNotifications.app"
rm -rf "$CLAUDE_DIR/ClaudeNotifications.app"  # remove old location
rm -f "$CLAUDE_DIR/Configure Notifications.command"  # remove legacy
rm -rf "$LAUNCHER_APP"
osacompile -o "$LAUNCHER_APP" \
  -e 'do shell script "python3 ~/.claude/config-ui.py &> /dev/null &"'
cp "$CLAUDE_DIR/Claude.icns" "$LAUNCHER_APP/Contents/Resources/applet.icns"
# Remove Assets.car — osacompile puts a default script icon in it that overrides applet.icns on modern macOS
rm -f "$LAUNCHER_APP/Contents/Resources/Assets.car"
$LSREGISTER -f "$LAUNCHER_APP"
touch "$LAUNCHER_APP"

# 8b. Flush icon caches so macOS picks up new icons
echo "Flushing icon cache..."
rm -rf ~/Library/Caches/com.apple.iconservices.store 2>/dev/null || true
find /var/folders -name "com.apple.iconservicesagent" -type d -exec rm -rf {} + 2>/dev/null || true
killall Dock 2>/dev/null || true

# 9. Add hooks to settings.json
echo "Configuring hooks in settings.json..."
python3 -c "
import json, os

settings_path = os.path.expanduser('$CLAUDE_DIR/settings.json')

# Load existing settings or start fresh
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

# Define the notification hooks
hook_entry = lambda: [{'matcher': '', 'hooks': [{'type': 'command', 'command': 'bash ~/.claude/notify.sh'}]}]

# Merge hooks — add missing ones, preserve existing
hooks = settings.get('hooks', {})
added = []
for event in ['Notification', 'PermissionRequest', 'Stop']:
    if event not in hooks:
        hooks[event] = hook_entry()
        added.append(event)

settings['hooks'] = hooks

# Write back with formatting preserved
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')

if added:
    print(f'Added hooks: {\", \".join(added)}')
else:
    print('All hooks already configured.')
"

echo ""
echo "=== Installation complete ==="
echo ""
echo "IF ALERT STYLES WERE NOT AUTO-CONFIGURED (see warnings above):"
echo "  1. System Settings > Notifications > ClaudeNotifications (Persistent) > set Alert Style to 'Alerts'"
echo "  2. System Settings > Notifications > ClaudeNotifications (Vanishing) > leave as 'Banners'"
echo ""
echo "Configure settings:"
echo "  Double-click: /Applications/ClaudeNotifications.app"
echo "  Or search:    'ClaudeNotifications' in Spotlight / Launchpad"
echo "  Or run:       python3 ~/.claude/config-ui.py"
echo ""
echo "Uninstall:"
echo "  ./uninstall.sh"
echo ""
echo "Test with:"
echo "  echo '{\"hook_event_name\":\"Stop\"}' | bash ~/.claude/notify.sh"
echo "  echo '{\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\"}' | bash ~/.claude/notify.sh"
