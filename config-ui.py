#!/usr/bin/env python3
"""Claude Code Notifications — Settings UI

Browser-based configuration interface for notify-config.json.
No external dependencies — uses only Python 3 stdlib.

Usage: python3 ~/.claude/config-ui.py
"""

import http.server
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import webbrowser

CONFIG_PATH = os.path.expanduser("~/.claude/notify-config.json")

# Heartbeat state — browser sends POST /api/heartbeat every 3s.
# Watchdog thread shuts down the server if no heartbeat for 10s (after 30s grace period).
_last_heartbeat = time.time()
_heartbeat_lock = threading.Lock()

VALID_SOUNDS = [
    "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass",
    "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi",
    "Submarine", "Tink",
]

EVENT_META = {
    "permission_request": {
        "label": "Permission Request",
        "description": "Fires when Claude shows a real permission dialog that needs your action.",
    },
    "permission_prompt": {
        "label": "Permission Prompt",
        "description": "Fires for permission events including auto-approved ones. Usually too noisy — keep disabled.",
    },
    "idle_prompt": {
        "label": "Idle Prompt",
        "description": "Fires when Claude is idle after responding. Not when blocked. Usually too noisy.",
    },
    "elicitation_dialog": {
        "label": "Question Dialog",
        "description": "Fires when Claude asks you a question and is waiting for your answer.",
    },
    "stop": {
        "label": "Task Complete",
        "description": "Fires when Claude finishes responding to your request.",
    },
}

EVENT_ORDER = ["permission_request", "elicitation_dialog", "stop", "permission_prompt", "idle_prompt"]

DEFAULT_CONFIG = {
    "default_sound": "Funk",
    "default_volume": 7,
    "default_style": "persistent",
    "events": {
        "permission_request": {"enabled": True, "sound": "Funk", "volume": 7, "style": "persistent"},
        "permission_prompt": {"enabled": False},
        "idle_prompt": {"enabled": False},
        "elicitation_dialog": {"enabled": True, "sound": "Glass", "volume": 7, "style": "persistent"},
        "stop": {"enabled": True, "sound": "Hero", "volume": 7, "style": "banner"},
    },
}

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Code Notifications — Settings</title>
<style>
  :root {
    --orange: #da7756;
    --orange-light: #f0c4b4;
    --orange-bg: #fdf6f3;
    --gray-50: #f9fafb;
    --gray-100: #f3f4f6;
    --gray-200: #e5e7eb;
    --gray-300: #d1d5db;
    --gray-400: #9ca3af;
    --gray-500: #6b7280;
    --gray-700: #374151;
    --gray-900: #111827;
    --green: #059669;
    --red: #dc2626;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--gray-50);
    color: var(--gray-900);
    line-height: 1.5;
    padding: 2rem 1rem;
    max-width: 720px;
    margin: 0 auto;
  }
  h1 {
    font-size: 1.5rem;
    font-weight: 600;
    margin-bottom: 0.25rem;
  }
  .subtitle {
    color: var(--gray-500);
    font-size: 0.875rem;
    margin-bottom: 1.5rem;
  }
  .card {
    background: white;
    border: 1px solid var(--gray-200);
    border-radius: 0.75rem;
    padding: 1.25rem;
    margin-bottom: 1rem;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
    transition: opacity 0.2s;
  }
  .card.disabled { opacity: 0.5; }
  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 0.75rem;
  }
  .card-title { font-weight: 600; font-size: 1rem; }
  .card-desc { color: var(--gray-500); font-size: 0.8125rem; margin-top: 0.125rem; }
  .defaults-title {
    font-size: 1.125rem;
    font-weight: 600;
    margin-bottom: 0.125rem;
    color: var(--gray-700);
  }

  /* Toggle switch */
  .toggle {
    position: relative;
    width: 44px; height: 24px;
    flex-shrink: 0;
  }
  .toggle input { opacity: 0; width: 0; height: 0; }
  .toggle .slider {
    position: absolute; inset: 0;
    background: var(--gray-300);
    border-radius: 12px;
    cursor: pointer;
    transition: background 0.2s;
  }
  .toggle .slider::before {
    content: "";
    position: absolute;
    width: 18px; height: 18px;
    left: 3px; bottom: 3px;
    background: white;
    border-radius: 50%;
    transition: transform 0.2s;
  }
  .toggle input:checked + .slider { background: var(--orange); }
  .toggle input:checked + .slider::before { transform: translateX(20px); }

  /* Controls grid */
  .controls {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 0.75rem;
    margin-top: 0.75rem;
  }
  .control-group { display: flex; flex-direction: column; gap: 0.25rem; }
  .control-group.full-width { grid-column: 1 / -1; }
  label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--gray-500);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }
  select, input[type=range] {
    width: 100%;
    height: 36px;
    border: 1px solid var(--gray-200);
    border-radius: 0.5rem;
    padding: 0 0.5rem;
    font-size: 0.875rem;
    background: white;
    color: var(--gray-900);
  }
  select:focus { outline: 2px solid var(--orange); outline-offset: -1px; }
  input[type=range] {
    -webkit-appearance: none;
    border: none;
    padding: 0;
    background: transparent;
    height: 36px;
  }
  input[type=range]::-webkit-slider-runnable-track {
    height: 6px;
    background: var(--gray-200);
    border-radius: 3px;
  }
  input[type=range]::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 18px; height: 18px;
    background: var(--orange);
    border-radius: 50%;
    margin-top: -6px;
    cursor: pointer;
  }
  .volume-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }
  .volume-row input { flex: 1; }
  .volume-val {
    font-size: 0.8125rem;
    color: var(--gray-500);
    min-width: 1.5rem;
    text-align: right;
  }

  /* Radio group for style */
  .radio-group {
    display: flex;
    gap: 0;
    border: 1px solid var(--gray-200);
    border-radius: 0.5rem;
    overflow: hidden;
    height: 36px;
  }
  .radio-group label {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 0.8125rem;
    font-weight: 500;
    text-transform: none;
    letter-spacing: 0;
    color: var(--gray-700);
    cursor: pointer;
    background: white;
    transition: background 0.15s, color 0.15s;
    border-right: 1px solid var(--gray-200);
    user-select: none;
  }
  .radio-group label:last-child { border-right: none; }
  .radio-group input { display: none; }
  .radio-group input:checked + span {
    /* parent label gets styled via JS */
  }
  .radio-group label.active {
    background: var(--orange);
    color: white;
  }

  /* Preview button */
  .btn-preview {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    height: 36px;
    padding: 0 0.75rem;
    border: 1px solid var(--gray-200);
    border-radius: 0.5rem;
    background: white;
    color: var(--gray-700);
    font-size: 0.8125rem;
    cursor: pointer;
    transition: border-color 0.15s;
  }
  .btn-preview:hover { border-color: var(--orange); }

  /* Save area */
  .save-area {
    display: flex;
    align-items: center;
    gap: 1rem;
    margin-top: 1.5rem;
  }
  .btn-save {
    height: 40px;
    padding: 0 1.5rem;
    background: var(--orange);
    color: white;
    border: none;
    border-radius: 0.5rem;
    font-size: 0.9375rem;
    font-weight: 600;
    cursor: pointer;
    transition: opacity 0.15s;
  }
  .btn-save:hover { opacity: 0.9; }
  .btn-save:active { opacity: 0.8; }
  .save-msg {
    font-size: 0.875rem;
    font-weight: 500;
    opacity: 0;
    transition: opacity 0.3s;
  }
  .save-msg.show { opacity: 1; }
  .save-msg.ok { color: var(--green); }
  .save-msg.err { color: var(--red); }

  .divider {
    border: none;
    border-top: 1px solid var(--gray-200);
    margin: 1.5rem 0;
  }
</style>
</head>
<body>

<h1>Claude Code Notifications</h1>
<p class="subtitle">Configure notification sounds, volume, and alert styles.</p>

<div id="app">Loading...</div>

<script>
const SOUNDS = %%SOUNDS%%;
const EVENT_META = %%EVENT_META%%;
const EVENT_ORDER = %%EVENT_ORDER%%;

let config = null;

async function loadConfig() {
  const res = await fetch('/api/config');
  config = await res.json();
  render();
}

function getEventVal(key, field) {
  const evt = (config.events || {})[key] || {};
  if (field === 'enabled') return evt.enabled !== undefined ? evt.enabled : true;
  if (field === 'sound') return evt.sound || config.default_sound || 'Funk';
  if (field === 'volume') return evt.volume !== undefined ? evt.volume : (config.default_volume !== undefined ? config.default_volume : 7);
  if (field === 'style') return evt.style || config.default_style || 'persistent';
  return undefined;
}

function setEventVal(key, field, value) {
  if (!config.events) config.events = {};
  if (!config.events[key]) config.events[key] = {};
  config.events[key][field] = value;
}

function render() {
  const app = document.getElementById('app');
  let html = '';

  // Defaults card
  html += `<div class="card">
    <div class="defaults-title">Defaults</div>
    <div class="card-desc">Fallback values for events that don't specify their own settings.</div>
    <div class="controls">
      <div class="control-group">
        <label>Sound</label>
        <select id="def-sound" onchange="config.default_sound=this.value">
          ${SOUNDS.map(s => `<option value="${s}" ${s===config.default_sound?'selected':''}>${s}</option>`).join('')}
        </select>
      </div>
      <div class="control-group">
        <label>Volume</label>
        <div class="volume-row">
          <input type="range" id="def-volume" min="1" max="20" value="${config.default_volume||7}"
            oninput="config.default_volume=+this.value;this.nextElementSibling.textContent=this.value">
          <span class="volume-val">${config.default_volume||7}</span>
        </div>
      </div>
      <div class="control-group">
        <label>Style</label>
        <div class="radio-group" id="def-style-group">
          <label class="${(config.default_style||'persistent')==='persistent'?'active':''}"
            onclick="setRadio('def-style-group','persistent');config.default_style='persistent'">
            <input type="radio" name="def-style" value="persistent" ${(config.default_style||'persistent')==='persistent'?'checked':''}><span>Persistent</span>
          </label>
          <label class="${(config.default_style||'persistent')==='banner'?'active':''}"
            onclick="setRadio('def-style-group','banner');config.default_style='banner'">
            <input type="radio" name="def-style" value="banner" ${(config.default_style||'persistent')==='banner'?'checked':''}><span>Banner</span>
          </label>
        </div>
      </div>
      <div class="control-group">
        <label>&nbsp;</label>
        <button class="btn-preview" onclick="preview(config.default_sound||'Funk',config.default_volume||7,config.default_style||'persistent')">&#9654; Preview</button>
      </div>
    </div>
  </div>`;

  html += '<hr class="divider">';

  // Event cards
  for (const key of EVENT_ORDER) {
    const meta = EVENT_META[key] || {label: key, description: ''};
    const enabled = getEventVal(key, 'enabled');
    const sound = getEventVal(key, 'sound');
    const volume = getEventVal(key, 'volume');
    const style = getEventVal(key, 'style');

    html += `<div class="card ${enabled?'':'disabled'}" id="card-${key}">
      <div class="card-header">
        <div>
          <div class="card-title">${meta.label}</div>
          <div class="card-desc">${meta.description}</div>
        </div>
        <label class="toggle">
          <input type="checkbox" ${enabled?'checked':''} onchange="toggleEvent('${key}',this.checked)">
          <span class="slider"></span>
        </label>
      </div>
      <div class="controls">
        <div class="control-group">
          <label>Sound</label>
          <select id="sound-${key}" onchange="setEventVal('${key}','sound',this.value)" ${enabled?'':'disabled'}>
            ${SOUNDS.map(s => `<option value="${s}" ${s===sound?'selected':''}>${s}</option>`).join('')}
          </select>
        </div>
        <div class="control-group">
          <label>Volume</label>
          <div class="volume-row">
            <input type="range" id="vol-${key}" min="1" max="20" value="${volume}" ${enabled?'':'disabled'}
              oninput="setEventVal('${key}','volume',+this.value);this.nextElementSibling.textContent=this.value">
            <span class="volume-val">${volume}</span>
          </div>
        </div>
        <div class="control-group">
          <label>Style</label>
          <div class="radio-group" id="style-${key}">
            <label class="${style==='persistent'?'active':''}"
              onclick="if(!this.closest('.card').classList.contains('disabled')){setRadio('style-${key}','persistent');setEventVal('${key}','style','persistent')}">
              <input type="radio" name="style-${key}" value="persistent" ${style==='persistent'?'checked':''} ${enabled?'':'disabled'}><span>Persistent</span>
            </label>
            <label class="${style==='banner'?'active':''}"
              onclick="if(!this.closest('.card').classList.contains('disabled')){setRadio('style-${key}','banner');setEventVal('${key}','style','banner')}">
              <input type="radio" name="style-${key}" value="banner" ${style==='banner'?'checked':''} ${enabled?'':'disabled'}><span>Banner</span>
            </label>
          </div>
        </div>
        <div class="control-group">
          <label>&nbsp;</label>
          <button class="btn-preview" onclick="preview(getEvtSound('${key}'),getEvtVol('${key}'),getEventVal('${key}','style'),'${key}')" ${enabled?'':'disabled'}>&#9654; Preview</button>
        </div>
      </div>
    </div>`;
  }

  html += `<div class="save-area">
    <button class="btn-save" onclick="saveConfig()">Save Settings</button>
    <span class="save-msg" id="save-msg"></span>
  </div>`;

  app.innerHTML = html;
}

function setRadio(groupId, value) {
  const group = document.getElementById(groupId);
  if (!group) return;
  group.querySelectorAll('label').forEach(l => {
    const input = l.querySelector('input');
    if (input.value === value) {
      input.checked = true;
      l.classList.add('active');
    } else {
      input.checked = false;
      l.classList.remove('active');
    }
  });
}

function toggleEvent(key, checked) {
  setEventVal(key, 'enabled', checked);
  render();
}

function getEvtSound(key) { return getEventVal(key, 'sound'); }
function getEvtVol(key) { return getEventVal(key, 'volume'); }

async function preview(sound, volume, style, eventKey) {
  await fetch('/api/preview', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({sound, volume, style, event_key: eventKey || null}),
  });
}

async function saveConfig() {
  const msg = document.getElementById('save-msg');
  try {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(config),
    });
    if (!res.ok) throw new Error(await res.text());
    msg.textContent = 'Saved!';
    msg.className = 'save-msg show ok';
  } catch (e) {
    msg.textContent = 'Error: ' + e.message;
    msg.className = 'save-msg show err';
  }
  setTimeout(() => { msg.classList.remove('show'); }, 2500);
}

loadConfig();

// Heartbeat — tells the server the browser tab is still open
setInterval(() => fetch('/api/heartbeat', {method: 'POST'}).catch(() => {}), 3000);
</script>
</body>
</html>"""


NOTIFIER_PERSISTENT = os.path.expanduser(
    "~/.claude/ClaudeNotifierPersistent.app/Contents/MacOS/terminal-notifier"
)
NOTIFIER_BANNER = os.path.expanduser(
    "~/.claude/ClaudeNotifierBanner.app/Contents/MacOS/terminal-notifier"
)
NOTIFIER_LEGACY = os.path.expanduser(
    "~/.claude/ClaudeNotifier.app/Contents/MacOS/terminal-notifier"
)

def _detect_terminal_bundle():
    term = os.environ.get("TERM_PROGRAM", "")
    mapping = {
        "WarpTerminal": "dev.warp.Warp-Stable",
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
    }
    return mapping.get(term, "dev.warp.Warp-Stable")  # fallback to Warp

TERMINAL_BUNDLE = _detect_terminal_bundle()

PREVIEW_TITLES = {
    "permission_request": "Claude Code - Permission Required",
    "permission_prompt": "Claude Code - Action Required",
    "idle_prompt": "Claude Code - Action Required",
    "elicitation_dialog": "Claude Code - Action Required",
    "stop": "Claude Code - Done",
}

PREVIEW_BODIES = {
    "permission_request": "Approve: Bash (preview)",
    "permission_prompt": "Permission required (preview)",
    "idle_prompt": "Waiting for your input (preview)",
    "elicitation_dialog": "Claude has a question (preview)",
    "stop": "Finished responding (preview)",
}


def _send_preview_notification(style, event_key=None):
    """Send a preview macOS notification using the appropriate notifier app."""
    if style == "banner":
        notifier = NOTIFIER_BANNER
        group = "claude-code-banner"
    else:
        notifier = NOTIFIER_PERSISTENT
        group = "claude-code-persistent"

    # Fallback to legacy app
    if not os.path.isfile(notifier):
        if os.path.isfile(NOTIFIER_LEGACY):
            notifier = NOTIFIER_LEGACY
            group = "claude-code"
        else:
            return  # No notifier available

    title = PREVIEW_TITLES.get(event_key, "Claude Code")
    body = PREVIEW_BODIES.get(event_key, "Preview notification")

    subprocess.Popen(
        [
            notifier,
            "-title", title,
            "-message", body,
            "-activate", TERMINAL_BUNDLE,
            "-group", group,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


class Handler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for the config UI."""

    def log_message(self, fmt, *args):
        # Suppress default request logging
        pass

    def _send_json(self, data, status=200):
        body = json.dumps(data, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, html):
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_error(self, status, message):
        body = message.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length)

    def do_GET(self):
        if self.path == "/":
            page = HTML_PAGE
            page = page.replace("%%SOUNDS%%", json.dumps(VALID_SOUNDS))
            page = page.replace("%%EVENT_META%%", json.dumps(EVENT_META))
            page = page.replace("%%EVENT_ORDER%%", json.dumps(EVENT_ORDER))
            self._send_html(page)
        elif self.path == "/api/config":
            try:
                with open(CONFIG_PATH) as f:
                    data = json.load(f)
            except FileNotFoundError:
                data = DEFAULT_CONFIG.copy()
            except json.JSONDecodeError:
                data = DEFAULT_CONFIG.copy()
            self._send_json(data)
        else:
            self._send_error(404, "Not found")

    def do_POST(self):
        if self.path == "/api/config":
            try:
                body = self._read_body()
                data = json.loads(body)
                with open(CONFIG_PATH, "w") as f:
                    json.dump(data, f, indent=2)
                    f.write("\n")
                self._send_json({"ok": True})
            except json.JSONDecodeError:
                self._send_error(400, "Invalid JSON")
            except Exception as e:
                self._send_error(500, str(e))

        elif self.path == "/api/heartbeat":
            global _last_heartbeat
            with _heartbeat_lock:
                _last_heartbeat = time.time()
            self._send_json({"ok": True})

        elif self.path in ("/api/preview", "/api/preview-sound"):
            try:
                body = self._read_body()
                data = json.loads(body)
                sound = data.get("sound", "Funk")
                volume = data.get("volume", 7)
                style = data.get("style", "persistent")
                event_key = data.get("event_key")

                # Validate sound name against allowlist
                if sound not in VALID_SOUNDS:
                    self._send_error(400, f"Invalid sound: {sound}")
                    return

                # Validate volume is a number in range
                try:
                    volume = int(volume)
                    volume = max(1, min(20, volume))
                except (ValueError, TypeError):
                    volume = 7

                # Validate style
                if style not in ("persistent", "banner"):
                    style = "persistent"

                # Send macOS notification via the appropriate notifier app
                _send_preview_notification(style, event_key)

                # Play alert sound
                sound_path = f"/System/Library/Sounds/{sound}.aiff"
                if os.path.exists(sound_path):
                    subprocess.Popen(
                        ["afplay", sound_path, "-v", str(volume)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                self._send_json({"ok": True})
            except json.JSONDecodeError:
                self._send_error(400, "Invalid JSON")
            except Exception as e:
                self._send_error(500, str(e))

        else:
            self._send_error(404, "Not found")


class ThreadedServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def find_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def main():
    port = find_free_port()
    server = ThreadedServer(("127.0.0.1", port), Handler)
    url = f"http://127.0.0.1:{port}"

    print(f"Claude Code Notifications — Settings UI")
    print(f"Listening on {url}")
    print(f"Press Ctrl+C to stop.\n")

    # Open browser after a brief delay to ensure server is ready
    def open_browser():
        webbrowser.open(url)

    threading.Timer(0.3, open_browser).start()

    def shutdown(sig, frame):
        print("\nShutting down...")
        os._exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    # Watchdog: auto-shutdown when browser tab is closed
    def watchdog():
        grace = 30  # seconds to wait for browser to open and load
        time.sleep(grace)
        while True:
            time.sleep(2)
            with _heartbeat_lock:
                elapsed = time.time() - _last_heartbeat
            if elapsed > 10:
                print("\nBrowser tab closed — shutting down.")
                os._exit(0)

    wd = threading.Thread(target=watchdog, daemon=True)
    wd.start()

    server.serve_forever()


if __name__ == "__main__":
    main()
