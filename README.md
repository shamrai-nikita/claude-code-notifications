# Claude Code Notifications for macOS

Native macOS notifications when Claude Code needs your attention or finishes a task. Configurable sounds and a browser-based settings UI.

## What you get

- **Persistent or temporary notifications** — choose per event type
- **Configurable sounds and volume** per event type, with per-event mute
- **Auto-dismiss** — persistent notifications clear automatically when you take action
- **Browser-based settings UI**

## Install

```bash
./install.sh
```

Restart any running Claude Code sessions.

## Events

| Event | Description | Default style |
|---|---|---|
| Permission request | Claude needs you to approve an action | Persistent |
| Question | Claude is asking you something | Persistent |
| Done | Claude finished responding | Temporary |

## Settings

```bash
open /Applications/ClaudeNotifications.app
# or: python3 ~/.claude/config-ui.py
```

Toggle events, pick sounds, adjust volume, choose persistent vs temporary, and preview — all from the browser.

## Uninstall

```bash
./uninstall.sh
```

Or drag `/Applications/ClaudeNotifications.app` to Trash — cleanup happens automatically on the next Claude Code hook event.

## Requirements

- macOS 14+
- Homebrew
- Claude Code CLI
