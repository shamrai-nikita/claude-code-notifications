# Claude Code Notifications — macOS

Native macOS notification system for Claude Code. Shows notifications with a custom bell-with-sparkle icon and configurable sounds when Claude needs attention or finishes a task. Supports per-event persistent or banner alert styles.

## Architecture

```
~/.claude/
├── notify.sh                       # Main script — hook handler
├── notify-click.sh                 # Click handler — activates terminal + switches tab
├── notify-config.json              # User config (sounds, volume, style, enable/disable per event)
├── config-ui.py                    # Browser-based settings UI (python3, zero deps, auto-shutdown)
├── ClaudeNotifierPersistent.app/   # Persistent alert style (stays on screen)
│   └── Contents/
│       ├── Info.plist              # Bundle ID: com.anthropic.claude-code-notifier-persistent
│       ├── MacOS/terminal-notifier
│       └── Resources/Claude.icns
├── ClaudeNotifierBanner.app/       # Banner alert style (auto-dismisses)
│   └── Contents/
│       ├── Info.plist              # Bundle ID: com.anthropic.claude-code-notifier-banner
│       ├── MacOS/terminal-notifier
│       └── Resources/Claude.icns
├── claude-icon-large.png           # Custom bell-with-sparkle icon (copied from repo icon.png)
└── Claude.icns                     # macOS icon set generated from the PNG

/Applications/
└── ClaudeNotifications.app/        # Settings launcher (built by install.sh via osacompile)
```

## How it works

Claude Code hooks (defined in `~/.claude/settings.json`) trigger `notify.sh` on three events:

| Hook Event | When it fires | Config key |
|---|---|---|
| `PermissionRequest` | A real permission dialog is shown (needs user action) | `permission_request` |
| `Notification` | Claude sends a built-in notification (elicitation dialog, etc.) | `elicitation_dialog` |
| `Stop` | Claude finishes responding | `stop` |

The script reads JSON from stdin (hook event data), loads `notify-config.json`, and:
1. Resolves event key, title, body text
2. Checks if the event is `enabled` in config — exits if disabled
3. Selects the correct notifier app based on the event's `style` setting (persistent or banner)
4. Sends notification via the selected `ClaudeNotifier*.app`
5. Plays sound via `afplay` at configured volume (skipped if `sound_enabled` is false)

Clicking a notification activates the terminal and switches to the correct tab. The terminal is auto-detected from `$TERM_PROGRAM`:

| `$TERM_PROGRAM` | Terminal | Tab switching |
|---|---|---|
| `WarpTerminal` | Warp | App-level only (no AppleScript support) |
| `iTerm.app` | iTerm2 | Full — switches to exact session tab via AppleScript |
| `Apple_Terminal` | Terminal.app | Full — focuses window by TTY via AppleScript |
| Other/missing | Detected app or none | App-level only |

## Key design decisions

- **Two app bundles**: macOS locks notification style to the app bundle. To support per-event persistent vs banner, we build two variants of the notifier app with different bundle IDs and `NSUserNotificationAlertStyle` values.
- **Legacy fallback**: If the selected variant app doesn't exist, `notify.sh` falls back to the legacy single `ClaudeNotifier.app` for backward compatibility.
- **Custom app bundles**: macOS locks notification icon to the sending app. `-appIcon` flag doesn't work on modern macOS. Solution: copy `terminal-notifier.app`, change bundle ID/name/icon. Uses a custom bell-with-sparkle icon (`icon.png` in repo). Binaries are re-signed with `codesign -s - --identifier <bundle-id>` so macOS treats them as distinct apps (not the original `terminal-notifier`). `notify.sh` also passes `-sender <bundle-id>` to reinforce the identity.
- **Alert style**: Set via `NSUserNotificationAlertStyle` in Info.plist (`alert` for persistent, `banner` for banner). User must also configure in System Settings > Notifications.
- **Terminal auto-detection**: `notify.sh` reads `$TERM_PROGRAM` to detect the terminal and captures a tab identifier (iTerm2 session ID, Terminal.app TTY). On click, `notify-click.sh` uses AppleScript to switch to the exact tab. Warp lacks AppleScript tab support, so only app-level activation is possible.
- **`-execute` over `-activate`**: `terminal-notifier` flags are mutually exclusive. We use `-execute` to run `notify-click.sh` on click, which both activates the app and switches tabs. Falls back to no activation flag if terminal is unknown.
- **Single python3 call**: All JSON parsing (stdin + config file) in one python3 invocation for performance.
- **Invisible launcher**: `ClaudeNotifications.app` is installed to `/Applications/` (visible in Spotlight/Launchpad). It's a minimal AppleScript app built via `osacompile` at install time. It runs the Python server as a background process (`do shell script ... &`), so no Terminal window is shown — the browser simply opens.
- **Settings UI**: Self-contained Python 3 script (`config-ui.py`) serves a browser-based UI on localhost. Zero external dependencies.
- **Heartbeat auto-shutdown**: The browser sends `POST /api/heartbeat` every 3s. A watchdog daemon thread waits 30s (grace period for browser to open), then exits if no heartbeat for 10s. This means closing the browser tab auto-stops the server.

## Config: notify-config.json

```json
{
  "default_sound": "Funk",
  "default_volume": 7,
  "default_style": "persistent",
  "default_sound_enabled": true,
  "events": {
    "permission_request": { "enabled": true, "sound": "Funk", "volume": 7, "style": "persistent", "sound_enabled": true },
    "elicitation_dialog": { "enabled": true, "sound": "Glass", "volume": 7, "style": "persistent", "sound_enabled": true },
    "stop":               { "enabled": true, "sound": "Hero", "volume": 7, "style": "banner", "sound_enabled": true }
  }
}
```

- **`enabled`**: `true`/`false` — skip notification entirely when false
- **`sound`**: macOS system sound name — Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink
- **`volume`**: number passed to `afplay -v` (1=quiet, 7=normal, 10=loud, 20=very loud)
- **`style`**: `"persistent"` (stays on screen) or `"banner"` (auto-dismisses)
- **`sound_enabled`**: `true`/`false` — when false, notification is shown but no sound is played
- **`default_sound_enabled`**: fallback for events that don't specify `sound_enabled` (defaults to `true` if missing)
- Per-event settings fall back to `default_sound`/`default_volume`/`default_style`/`default_sound_enabled`, then hardcoded defaults (Funk/10/persistent/true)
- **Backward compat**: Missing `style` or `sound_enabled` fields default to their respective `default_*` values. Existing configs work unchanged.

## Settings UI

Launch the browser-based settings UI:

```bash
# Double-click in Finder / search in Spotlight / Launchpad:
open /Applications/ClaudeNotifications.app

# Or run directly:
python3 ~/.claude/config-ui.py
```

This opens a local web page where you can configure all notification settings: enable/disable events, choose sounds, adjust volume, mute sound per event, set persistent vs banner style, switch between dark/light themes, and preview notifications. The server auto-shuts down when the browser tab is closed (heartbeat watchdog).

## Hooks config in settings.json

Only the `hooks` section is relevant (the rest is user-specific):

```json
{
  "hooks": {
    "Notification": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/notify.sh" }] }
    ],
    "PermissionRequest": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/notify.sh" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/notify.sh" }] }
    ]
  }
}
```

## Installation (fresh machine)

```bash
./install.sh
```

This single command handles everything:
1. Installs `terminal-notifier` via Homebrew (if missing)
2. Copies custom icon from repo and converts to `.icns`
3. Builds two `ClaudeNotifier*.app` bundles (Persistent + Banner) with custom icon
4. Removes legacy `ClaudeNotifier.app` if present
5. Sends test notifications to trigger macOS permission prompts
6. Copies `notify.sh`, `notify-click.sh`, `notify-config.json`, and `config-ui.py` to `~/.claude/`
7. Builds `ClaudeNotifications.app` launcher (invisible — no Terminal window) to `/Applications/`
8. Automatically merges hooks into `~/.claude/settings.json` (creates if missing, preserves existing settings)

The installer auto-configures alert styles (persistent vs banner) by writing to `com.apple.ncprefs.plist`. If auto-configuration fails (warnings shown during install), set manually:
1. System Settings > Notifications > **ClaudeNotifications (Persistent)** > set Alert Style to **Alerts**
2. System Settings > Notifications > **ClaudeNotifications (Vanishing)** > leave as **Banners**

Then restart Claude Code sessions (or run `/hooks` to reload).

## Uninstall

```bash
./uninstall.sh
```

Removes all notification components:
1. Removes notification hooks from `~/.claude/settings.json` (preserves all other settings)
2. Clears delivered notifications
3. Unregisters app bundles from LaunchServices
4. Deletes all installed files (notify.sh, notify-click.sh, config, UI, icon, apps) and launcher from `/Applications/`
5. Removes entries from Notification Center database (`com.anthropic.claude-code-notifier*`) and restarts `usernoted` so they disappear from System Settings > Notifications

Does NOT remove `terminal-notifier` Homebrew package or `~/.claude/` directory. Idempotent — safe to run multiple times.

## Testing

```bash
# Test permission notification (persistent style)
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | bash ~/.claude/notify.sh

# Test stop notification (banner style by default)
echo '{"hook_event_name":"Stop","stop_hook_active":false}' | bash ~/.claude/notify.sh

# Test elicitation
echo '{"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Which approach?"}' | bash ~/.claude/notify.sh

# Launch settings UI
python3 ~/.claude/config-ui.py
```

## Files in this project

| File | Purpose |
|---|---|
| `CLAUDE.md` | This file — project context |
| `icon.png` | Custom bell-with-sparkle icon (2048x2048 JPEG, used for notifications and launcher) |
| `notify.sh` | Main notification script (hook handler) |
| `notify-click.sh` | Notification click handler — activates terminal + switches tab |
| `notify-config.json` | User-editable config |
| `config-ui.py` | Browser-based settings UI (with heartbeat auto-shutdown) |
| `ClaudeNotifications.app` | Settings launcher in `/Applications/` (built at install time via `osacompile`, not in repo) |
| `install.sh` | Setup script — builds notifier apps, copies icon, installs to ~/.claude/ and /Applications/ |
| `uninstall.sh` | Removes all notification components from ~/.claude/ and /Applications/ |
| `ClaudeNotifierPersistent.plist` | Info.plist template for the persistent alert app |
| `ClaudeNotifierBanner.plist` | Info.plist template for the banner alert app |
