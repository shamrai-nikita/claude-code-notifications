#!/bin/bash
# Claude Code Notifications — macOS installer
# Installs notification system to ~/.claude/
set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

echo "=== Claude Code Notifications Installer ==="

# 1. Locate terminal-notifier.app (Homebrew preferred, bundled fallback)
TN_APP=""

# Try Homebrew cellar first (Intel, then Apple Silicon)
TN_APP=$(find /usr/local/Cellar/terminal-notifier -name "terminal-notifier.app" -maxdepth 2 2>/dev/null | head -1)
if [ -z "$TN_APP" ]; then
  TN_APP=$(find /opt/homebrew/Cellar/terminal-notifier -name "terminal-notifier.app" -maxdepth 2 2>/dev/null | head -1)
fi

# If not in cellar, try brew install (only if brew exists)
if [ -z "$TN_APP" ] && command -v brew &>/dev/null; then
  echo "Installing terminal-notifier via Homebrew..."
  if brew install terminal-notifier 2>/dev/null; then
    TN_APP=$(find /usr/local/Cellar/terminal-notifier -name "terminal-notifier.app" -maxdepth 2 2>/dev/null | head -1)
    if [ -z "$TN_APP" ]; then
      TN_APP=$(find /opt/homebrew/Cellar/terminal-notifier -name "terminal-notifier.app" -maxdepth 2 2>/dev/null | head -1)
    fi
  fi
fi

# Fallback: bundled copy from repo
if [ -z "$TN_APP" ]; then
  if [ -d "$SCRIPT_DIR/vendor/terminal-notifier.app" ]; then
    TN_APP="$SCRIPT_DIR/vendor/terminal-notifier.app"
    echo "Using bundled terminal-notifier (Homebrew not available)."
  else
    echo "ERROR: Could not find terminal-notifier.app."
    echo "  - Homebrew is not installed (or brew install failed)"
    echo "  - Bundled copy not found at vendor/terminal-notifier.app"
    exit 1
  fi
else
  echo "Found terminal-notifier at: $TN_APP"
fi

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

# 4. Build single ClaudeNotifications.app bundle (alert style)
echo "Building ClaudeNotifications.app..."

# Remove all legacy app bundles
for legacy in "ClaudeNotifier.app" "ClaudeNotifierPersistent.app" "ClaudeNotifierBanner.app" "ClaudeNotifications Alerts.app" "ClaudeNotifications Banners.app"; do
  if [ -d "$CLAUDE_DIR/$legacy" ]; then
    echo "  Removing legacy $legacy..."
    "$LSREGISTER" -u "$CLAUDE_DIR/$legacy" 2>/dev/null || true
    rm -rf "$CLAUDE_DIR/$legacy"
  fi
done

APP_NAME="ClaudeNotifications.app"
rm -rf "$CLAUDE_DIR/$APP_NAME"
cp -R "$TN_APP" "$CLAUDE_DIR/$APP_NAME"
cp "$SCRIPT_DIR/ClaudeNotifications.plist" "$CLAUDE_DIR/$APP_NAME/Contents/Info.plist"
cp "$CLAUDE_DIR/Claude.icns" "$CLAUDE_DIR/$APP_NAME/Contents/Resources/Claude.icns"
# Re-sign with our bundle ID so macOS treats it as a distinct app (not the original terminal-notifier)
BUNDLE_ID=$(defaults read "$CLAUDE_DIR/$APP_NAME/Contents/Info.plist" CFBundleIdentifier)
codesign --force -s - --identifier "$BUNDLE_ID" "$CLAUDE_DIR/$APP_NAME" 2>/dev/null || true
touch "$CLAUDE_DIR/$APP_NAME"
$LSREGISTER -f "$CLAUDE_DIR/$APP_NAME"
echo "  $APP_NAME installed and registered."

# 5. Send test notification to trigger macOS permission prompt
echo "Triggering notification permission (you may see a test notification)..."
NOTIFIER="$CLAUDE_DIR/$APP_NAME/Contents/MacOS/terminal-notifier"
"$NOTIFIER" -title "Claude Code Setup" -message "Notifications enabled" -group "claude-setup" 2>/dev/null || true

# 5b. Set notification grouping to Off for the app bundle
echo "Setting notification grouping to Off (may take up to 15s)..."
python3 -c "
import subprocess, plistlib, sys, time

TARGET = 'com.anthropic.claude-code-notifier'

# Also clean up old bundle IDs from ncprefs
old_ids = [
    'com.anthropic.claude-code-notifier-persistent',
    'com.anthropic.claude-code-notifier-banner',
]

def kill_usernoted():
    subprocess.run(['killall', 'usernoted'], capture_output=True)

def read_plist():
    result = subprocess.run(['defaults', 'export', 'com.apple.ncprefs', '-'], capture_output=True)
    if result.returncode != 0:
        return None
    return plistlib.loads(result.stdout)

# Step 1: Kill usernoted to flush in-memory app registration to disk
kill_usernoted()
time.sleep(1)

# Step 2: Read ncprefs (app should now be on disk after flush)
pl = None
found = False
for attempt in range(3):
    pl = read_plist()
    if pl is None:
        break
    for app in pl.get('apps', []):
        if app.get('bundle-id', '') == TARGET:
            found = True
            break
    if found:
        break
    time.sleep(2)

if pl is None:
    print('  WARNING: Could not read notification preferences.')
    sys.exit(0)

# Step 3: If app not found after flush, insert a new entry as fallback
if not found:
    print('  App not in ncprefs after flush — inserting entry...')
    pl.setdefault('apps', []).append({
        'bundle-id': TARGET,
        'grouping': 2,
    })

# Step 4: Set grouping = 2 (Off) for target app, remove old entries
changed = not found  # already changed if we inserted
apps_to_keep = []
for app in pl.get('apps', []):
    bid = app.get('bundle-id', '')
    if bid in old_ids:
        changed = True
        continue  # Remove old entries
    if bid == TARGET:
        if app.get('grouping') != 2:
            app['grouping'] = 2
            changed = True
    apps_to_keep.append(app)

if changed:
    pl['apps'] = apps_to_keep
    data = plistlib.dumps(pl, fmt=plistlib.FMT_BINARY)
    # Step 5: Kill usernoted BEFORE writing so it can't overwrite our changes
    kill_usernoted()
    time.sleep(0.5)
    # Step 6: Write the modified plist — restarted usernoted reads our file
    wr = subprocess.run(['defaults', 'import', 'com.apple.ncprefs', '-'], input=data)
    if wr.returncode == 0:
        print('  Notification grouping set to Off.')
    else:
        print('  WARNING: Could not write notification preferences.')
else:
    print('  Notification grouping already set.')
"

# Remove the test notification (after grouping is set so it doesn't interfere with registration)
"$NOTIFIER" -remove "claude-setup" 2>/dev/null || true

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

# 7b. Install VS Code extension for terminal tab switching
echo "Installing VS Code extension..."
VSIX="$SCRIPT_DIR/vendor/claude-code-notifications.vsix"
_ext_installed=0
if [ -f "$VSIX" ]; then
  # Extract version from the VSIX's package.json (VSIX is a zip; extension/package.json has the version)
  _ext_version=$(python3 -c "
import zipfile, json, sys
try:
    with zipfile.ZipFile('$VSIX') as z:
        with z.open('extension/package.json') as f:
            print(json.load(f)['version'])
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
")
  if [ -z "$_ext_version" ]; then
    echo "  Could not read version from VSIX — skipping."
  else
    for _ext_entry in "$HOME/.cursor/extensions:Cursor" "$HOME/.vscode/extensions:VS Code" "$HOME/.vscode-oss/extensions:VSCodium"; do
      _ext_dir="${_ext_entry%%:*}"
      _editor="${_ext_entry##*:}"
      if [ -d "$_ext_dir" ]; then
        # Remove any old version(s)
        rm -rf "$_ext_dir"/anthropic.claude-code-notifications-*
        # Extract VSIX to temp dir, then move extension/ contents into place
        _tmpdir=$(mktemp -d)
        unzip -q "$VSIX" -d "$_tmpdir"
        mv "$_tmpdir/extension" "$_ext_dir/anthropic.claude-code-notifications-$_ext_version"
        rm -rf "$_tmpdir"
        # Register in extensions.json so the editor recognizes the extension
        python3 -c "
import json, sys, uuid, time, os
reg_path, ext_path, version = sys.argv[1], sys.argv[2], sys.argv[3]
dir_name = os.path.basename(ext_path)
exts = []
if os.path.exists(reg_path):
    with open(reg_path) as f:
        exts = json.load(f)
exts = [e for e in exts if e.get('identifier', {}).get('id') != 'anthropic.claude-code-notifications']
ext_uuid = str(uuid.uuid4())
exts.append({
    'identifier': {'id': 'anthropic.claude-code-notifications', 'uuid': ext_uuid},
    'version': version,
    'location': {'\$mid': 1, 'path': ext_path, 'scheme': 'file'},
    'relativeLocation': dir_name,
    'metadata': {
        'isApplicationScoped': False,
        'isMachineScoped': False,
        'isBuiltin': False,
        'installedTimestamp': int(time.time() * 1000),
        'pinned': False,
        'source': 'vsix',
        'id': ext_uuid,
        'publisherDisplayName': 'Anthropic',
        'targetPlatform': 'undefined',
        'updated': False,
        'isPreReleaseVersion': False,
        'hasPreReleaseVersion': False,
        'preRelease': False,
    },
})
with open(reg_path, 'w') as f:
    json.dump(exts, f, indent='\t')
    f.write('\n')
" "$_ext_dir/extensions.json" "$_ext_dir/anthropic.claude-code-notifications-$_ext_version" "$_ext_version" 2>/dev/null || true
        echo "  Installed for $_editor."
        _ext_installed=$((_ext_installed + 1))
      fi
    done
    if [ "$_ext_installed" -eq 0 ]; then
      echo "  No VS Code/Cursor/VSCodium extensions directory found — skipping."
      echo "  (Terminal tab switching will use app-level activation only.)"
    fi
  fi
else
  echo "  VSIX not found — skipping. (Build with: cd vscode-extension && npx @vscode/vsce package)"
fi

# 8. Build clickable launcher app (in /Applications/ for Spotlight/Launchpad)
echo "Building ClaudeNotifications.app launcher..."
LAUNCHER_APP="/Applications/ClaudeNotifications.app"
rm -f "$CLAUDE_DIR/Configure Notifications.command"  # remove legacy
rm -rf "$LAUNCHER_APP"
osacompile -o "$LAUNCHER_APP" \
  -e 'do shell script "python3 ~/.claude/config-ui.py &> /dev/null &"'
cp "$CLAUDE_DIR/Claude.icns" "$LAUNCHER_APP/Contents/Resources/applet.icns"
# Remove Assets.car — osacompile puts a default script icon in it that overrides applet.icns on modern macOS
rm -f "$LAUNCHER_APP/Contents/Resources/Assets.car"
$LSREGISTER -f "$LAUNCHER_APP"
touch "$LAUNCHER_APP"
touch "$CLAUDE_DIR/.notify-installed"

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
for event in ['Notification', 'PermissionRequest', 'Stop', 'PostToolUse', 'UserPromptSubmit']:
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

# 10. Prompt user to enable notifications in System Settings
echo ""
echo "=== Enable Notifications ==="
echo "System Settings will open to the Notifications page."
echo "Please enable notifications for:"
echo "  - ClaudeNotifications"
echo ""
osascript -e 'tell application id "com.apple.systempreferences" to quit' 2>/dev/null || true
sleep 0.5
open "x-apple.systempreferences:com.apple.Notifications-Settings"
read -p "Press Enter once you've enabled notifications..."

echo ""
echo "=== Installation complete ==="
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
