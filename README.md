# Claude Code Notifications for macOS

Never miss when Claude Code needs your attention. Get native macOS notifications with the Claude icon and sound alerts when Claude asks for permission, has a question, or finishes a task.

## What you get

- **Persistent or banner notifications** — choose per event type
- **Claude icon** in the notification
- **Clicking the notification** opens your terminal (Warp)
- **Configurable sounds and volume** per event type
- **Browser-based settings UI** — no JSON editing required
- **Works globally** across all projects and sessions

## Install

```bash
./install.sh
```

Alert styles (persistent vs banner) are configured automatically. If you see warnings during install, set manually:
1. **System Settings > Notifications > ClaudeNotifications (Persistent)** — set Alert Style to **Alerts**
2. **System Settings > Notifications > ClaudeNotifications (Vanishing)** — leave as **Banners**

Restart any running Claude Code sessions.

## When you'll be notified

| Event | Description | Default | Style |
|---|---|---|---|
| Permission request | Claude needs you to approve an action | On | Persistent |
| Question | Claude is asking you a question | On | Persistent |
| Done | Claude finished responding | On | Banner |

## Settings UI

```bash
# Double-click in Finder:
open ~/.claude/Configure\ Notifications.command

# Or run directly:
python3 ~/.claude/config-ui.py
```

Opens a browser-based settings page where you can toggle events, pick sounds, adjust volume, choose persistent vs banner style, and preview sounds. The server automatically shuts down when you close the browser tab.

## Configuration

Edit `~/.claude/notify-config.json` directly, or use the settings UI above. Changes apply immediately.

```json
{
  "default_sound": "Funk",
  "default_volume": 7,
  "default_style": "persistent",
  "events": {
    "permission_request": { "enabled": true, "sound": "Funk", "volume": 7, "style": "persistent" },
    "elicitation_dialog": { "enabled": true, "sound": "Glass", "volume": 7, "style": "persistent" },
    "stop":               { "enabled": true, "sound": "Hero", "volume": 7, "style": "banner" }
  }
}
```

**Sound options:** Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink

**Volume:** 1 = quiet, 7 = normal, 10 = loud

**Style:** `"persistent"` (stays on screen until dismissed) or `"banner"` (auto-dismisses after a few seconds)

## Uninstall

```bash
./uninstall.sh
```

Removes all notification hooks, app bundles, and installed files from `~/.claude/`. Does not remove the `terminal-notifier` Homebrew package.

## Requirements

- macOS 14+
- Homebrew
- Claude Code CLI
