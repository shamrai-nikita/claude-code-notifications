# Claude Code Notifications — macOS

Native macOS notification system for Claude Code. Shows notifications with a custom bell-with-sparkle icon and configurable sounds when Claude needs attention or finishes a task. Supports per-event persistent or temporary alert styles with configurable auto-dismiss timeout.

## Architecture

```
~/.claude/
├── notify.sh                       # Main script — hook handler
├── notify-click.sh                 # Click handler — activates terminal + switches tab
├── notify-config.json              # User config (sounds, volume, style, timeout, enable/disable per event)
├── config-ui.py                    # Browser-based settings UI (python3, zero deps, auto-shutdown)
├── ClaudeNotifications.app/        # Single notifier app (alert style, dismiss via background timer)
│   └── Contents/
│       ├── Info.plist              # Bundle ID: com.anthropic.claude-code-notifier
│       ├── MacOS/terminal-notifier
│       └── Resources/Claude.icns
├── claude-icon-large.png           # Custom bell-with-sparkle icon (copied from repo icon.png)
├── Claude.icns                     # macOS icon set generated from the PNG
└── .notify-installed               # Marker file — enables trash-based uninstall detection

vendor/
└── terminal-notifier.app/          # Bundled terminal-notifier v2.0.0 (Homebrew fallback)

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
3. Sends notification via `ClaudeNotifications.app` (single app bundle, alert style)
4. For temporary style: spawns a background dismiss timer (`sleep $TIMEOUT && -remove`)
5. Plays sound via `afplay` at configured volume (skipped if `sound_enabled` is false)

Clicking a notification activates the terminal and switches to the correct tab. The terminal is auto-detected from `$TERM_PROGRAM`:

| `$TERM_PROGRAM` | Terminal | Tab switching |
|---|---|---|
| `WarpTerminal` | Warp | App-level only (no AppleScript support) |
| `iTerm.app` | iTerm2 | Full — switches to exact session tab via AppleScript |
| `Apple_Terminal` | Terminal.app | Full — focuses window by TTY via AppleScript |
| `vscode` | Cursor | App-level only |
| `vscode` | VS Code | App-level only |
| `vscode` | VSCodium | App-level only |
| Other/missing | Detected app or none | App-level only |

## Key design decisions

- **Single app bundle with background dismiss**: macOS locks notification style to the app bundle. Instead of two app bundles (Alerts + Banners), we use a single app with `alert` style and simulate "temporary" by spawning a background `(sleep $TIMEOUT && -remove)` process. This gives users one entry in System Settings > Notifications instead of two, plus configurable dismiss timeout (instead of macOS's fixed ~5s for banners).
- **Legacy fallback**: If the single app doesn't exist, `notify.sh` falls back to `ClaudeNotifications Alerts.app` → `ClaudeNotifierPersistent.app` → `ClaudeNotifier.app` for backward compatibility.
- **Custom app bundle**: macOS locks notification icon to the sending app. `-appIcon` flag doesn't work on modern macOS. Solution: copy `terminal-notifier.app`, change bundle ID/name/icon. Uses a custom bell-with-sparkle icon (`icon.png` in repo). Binary is re-signed with `codesign -s - --identifier <bundle-id>` so macOS treats it as a distinct app (not the original `terminal-notifier`). `notify.sh` also passes `-sender <bundle-id>` to reinforce the identity.
- **Alert style**: Set via `NSUserNotificationAlertStyle = alert` in Info.plist. The "temporary" behavior is achieved via `terminal-notifier -remove GROUP_ID` after a configurable timeout. User must configure in System Settings > Notifications.
- **Dismiss timer race conditions**: Each new notification kills the previous session's dismiss timer PID (stored in `.dpid` marker files) before sending. PostToolUse/UserPromptSubmit hooks also kill timers. If a timer fires on an already-dismissed notification, `-remove` is a no-op.
- **Terminal auto-detection**: `notify.sh` reads `$TERM_PROGRAM` to detect the terminal and captures a tab identifier (iTerm2 session ID, Terminal.app TTY). On click, `notify-click.sh` uses AppleScript to switch to the exact tab. Warp lacks AppleScript tab support, so only app-level activation is possible.
- **`-execute` over `-activate`**: `terminal-notifier` flags are mutually exclusive. We use `-execute` to run `notify-click.sh` on click, which both activates the app and switches tabs. Falls back to no activation flag if terminal is unknown.
- **Single python3 call**: All JSON parsing (stdin + config file) in one python3 invocation for performance.
- **Invisible launcher**: `ClaudeNotifications.app` is installed to `/Applications/` (visible in Spotlight/Launchpad). It's a minimal AppleScript app built via `osacompile` at install time. It runs the Python server as a background process (`do shell script ... &`), so no Terminal window is shown — the browser simply opens.
- **Settings UI**: Self-contained Python 3 script (`config-ui.py`) serves a browser-based UI on localhost. Zero external dependencies.
- **Heartbeat auto-shutdown**: The browser sends `POST /api/heartbeat` every 3s. A watchdog daemon thread waits 30s (grace period for browser to open), then exits if no heartbeat for 10s. This means closing the browser tab auto-stops the server.
- **Bundled terminal-notifier fallback**: A copy of `terminal-notifier.app` v2.0.0 (~476KB) is committed in `vendor/`. The installer prefers the Homebrew version (potentially newer) but falls back to the bundled copy when Homebrew is unavailable. This removes Homebrew from the hard requirements.

## Config: notify-config.json

```json
{
  "default_sound": "Funk",
  "default_volume": 7,
  "default_style": "banner",
  "default_sound_enabled": true,
  "default_timeout": 5,
  "events": {
    "permission_request": { "enabled": true, "sound": "Funk", "volume": 7, "style": "banner", "sound_enabled": true },
    "elicitation_dialog": { "enabled": true, "sound": "Glass", "volume": 7, "style": "banner", "sound_enabled": true },
    "stop":               { "enabled": true, "sound": "Hero", "volume": 7, "style": "banner", "sound_enabled": true }
  }
}
```

- **`enabled`**: `true`/`false` — skip notification entirely when false
- **`sound`**: macOS system sound name — Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink
- **`volume`**: number passed to `afplay -v` (1=quiet, 7=normal, 10=loud, 20=very loud)
- **`style`**: `"persistent"` (stays on screen) or `"banner"` (auto-dismisses after timeout)
- **`sound_enabled`**: `true`/`false` — when false, notification is shown but no sound is played
- **`timeout`**: seconds before a temporary notification auto-dismisses (1-60, default 5). Only applies when `style` is `"banner"`.
- **`default_timeout`**: fallback timeout for events that don't specify `timeout` (defaults to `5` if missing)
- **`default_sound_enabled`**: fallback for events that don't specify `sound_enabled` (defaults to `true` if missing)
- Per-event settings fall back to `default_sound`/`default_volume`/`default_style`/`default_sound_enabled`/`default_timeout`, then hardcoded defaults (Funk/7/banner/true/5)
- **Backward compat**: Missing `style`, `sound_enabled`, or `timeout` fields default to their respective `default_*` values. Existing configs work unchanged.

## Settings UI

Launch the browser-based settings UI:

```bash
# Double-click in Finder / search in Spotlight / Launchpad:
open /Applications/ClaudeNotifications.app

# Or run directly:
python3 ~/.claude/config-ui.py
```

This opens a local web page where you can configure all notification settings: enable/disable events, choose sounds, adjust volume, mute sound per event, set persistent vs temporary style, configure dismiss timeout, switch between dark/light themes, and preview notifications. The server auto-shuts down when the browser tab is closed (heartbeat watchdog).

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
1. Locates `terminal-notifier.app` — checks Homebrew cellar first, tries `brew install` if available, falls back to bundled copy in `vendor/`
2. Copies custom icon from repo and converts to `.icns`
3. Builds single `ClaudeNotifications.app` bundle with custom icon (removes all legacy app bundles)
4. Sends test notification to trigger macOS permission prompt
5. Copies `notify.sh`, `notify-click.sh`, `notify-config.json`, and `config-ui.py` to `~/.claude/`
6. Builds `ClaudeNotifications.app` launcher (invisible — no Terminal window) to `/Applications/`
7. Automatically merges hooks into `~/.claude/settings.json` (creates if missing, preserves existing settings)
8. Opens System Settings and prompts user to enable notifications

If auto-configuration fails (warnings shown during install), enable manually:
1. System Settings > Notifications > **ClaudeNotifications** > enable notifications

Then restart Claude Code sessions (or run `/hooks` to reload).

## Uninstall

Two ways to uninstall:

### Option 1: Drag to Trash (standard macOS way)

Drag `/Applications/ClaudeNotifications.app` to the Trash. The next time Claude Code fires a hook event, `notify.sh` detects the missing launcher and automatically cleans up all artifacts (hooks, scripts, config, app bundles, Notification Center entries). This is a full uninstall — identical to running the uninstall script.

**How it works:** The installer creates a `.notify-installed` marker file in `~/.claude/`. On every hook invocation, `notify.sh` checks if the launcher app still exists. If the app is gone and the marker is present, it runs a self-cleanup function and exits.

### Option 2: Uninstall script

```bash
./uninstall.sh
```

Interactive uninstall with confirmation prompt.

Both methods remove all notification components:
1. Removes notification hooks from `~/.claude/settings.json` (preserves all other settings)
2. Kills background dismiss timer processes
3. Clears delivered notifications
4. Unregisters app bundles from LaunchServices
5. Deletes all installed files (notify.sh, notify-click.sh, config, UI, icon, app bundles) and launcher from `/Applications/`
6. Removes entries from Notification Center database (`com.anthropic.claude-code-notifier*`) and restarts `usernoted` so they disappear from System Settings > Notifications

Neither method removes `terminal-notifier` Homebrew package (if installed) or `~/.claude/` directory. Both are idempotent — safe to run multiple times.

## Testing

```bash
# Test temporary notification (auto-dismisses after 5s)
echo '{"hook_event_name":"Stop","stop_hook_active":false}' | bash ~/.claude/notify.sh

# Test permission notification
echo '{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}' | bash ~/.claude/notify.sh

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
| `install.sh` | Setup script — builds notifier app, copies icon, installs to ~/.claude/ and /Applications/ |
| `uninstall.sh` | Removes all notification components from ~/.claude/ and /Applications/ |
| `ClaudeNotifications.plist` | Info.plist template for the notifier app (alert style) |
| `vendor/terminal-notifier.app` | Bundled terminal-notifier v2.0.0 (used when Homebrew is unavailable) |
