# Claude Code Notifications for macOS

Native macOS notifications when Claude Code needs your attention or finishes a task. Configurable sounds and a browser-based settings UI.

## Why use this

**Works with any terminal** — clicking a notification activates your terminal

**Customizable** — sound, volume, persistent vs temporary style, and enable/disable per event type.

**Browser-based settings UI** — configure everything from a local web page.

**Single-click install** — one script sets up everything.

| Permission request | Question | Done |
|---|---|---|
| ![Permission request](images/notification-permission-bash.png) | ![Question](images/notification-question.png) | ![Done](images/notification-done.png) |

## Install

Download the [latest release](https://github.com/shamrai-nikita/claude-code-notifications/releases/latest) or clone the repo:

```bash
git clone https://github.com/shamrai-nikita/claude-code-notifications.git
cd claude-code-notifications
```

Then run:

```bash
./install.sh
```

Restart any running Claude Code sessions.

## Settings UI

Find **Claude Notifications** in your Applications folder (or Spotlight / Launchpad):

<img src="images/app-icon.png" width="96" alt="Claude Notifications app icon">

Or launch from the terminal:

```bash
open /Applications/ClaudeNotifications.app
# or: python3 ~/.claude/config-ui.py
```

<details>
<summary>Settings UI preview</summary>

<img src="images/settings-ui.png" width="400" alt="Settings UI">

</details>

## Uninstall

```bash
./uninstall.sh
```

Or drag `/Applications/ClaudeNotifications.app` to Trash — cleanup happens automatically on the next Claude Code hook event.

## Requirements

- macOS 14+
- Homebrew
- Claude Code CLI
