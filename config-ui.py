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
"elicitation_dialog": {
        "label": "Question Dialog",
        "description": "Fires when Claude asks you a question and is waiting for your answer.",
    },
    "stop": {
        "label": "Task Complete",
        "description": "Fires when Claude finishes responding to your request.",
    },
}

EVENT_ORDER = ["permission_request", "elicitation_dialog", "stop"]

DEFAULT_CONFIG = {
    "global_enabled": True,
    "events": {
        "permission_request": {"enabled": True, "sound": "Funk", "volume": 7, "style": "persistent", "sound_enabled": True},
        "elicitation_dialog": {"enabled": True, "sound": "Glass", "volume": 7, "style": "persistent", "sound_enabled": True},
        "stop": {"enabled": True, "sound": "Hero", "volume": 7, "style": "banner", "sound_enabled": True},
    },
}

HTML_PAGE = r"""<!DOCTYPE html>
<html lang="en" data-theme="light">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Claude Code Notifications — Settings</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600&display=swap" rel="stylesheet">
<style>
  :root {
    --color-bg: #fafaf9;
    --color-surface: #ffffff;
    --color-accent: #d97757;
    --color-accent-hover: #c4694d;
    --color-accent-subtle: rgba(217,119,87,0.08);
    --color-text: #1c1917;
    --color-text-secondary: #78716c;
    --color-text-tertiary: #a8a29e;
    --color-border: #e7e5e4;
    --color-border-strong: #d6d3d1;
    --color-input-bg: #ffffff;
    --color-toggle-off: #d6d3d1;
    --color-toggle-knob: #ffffff;
    --color-green: #059669;
    --color-red: #dc2626;
    --color-seg-bg: #f5f5f4;
    --color-seg-active-bg: var(--color-accent);
    --color-seg-active-text: #ffffff;
  }
  [data-theme="dark"] {
    --color-bg: #0f0f12;
    --color-surface: #1a1a1f;
    --color-accent: #e88565;
    --color-accent-hover: #d4764a;
    --color-accent-subtle: rgba(232,133,101,0.1);
    --color-text: #e7e5e4;
    --color-text-secondary: #a8a29e;
    --color-text-tertiary: #78716c;
    --color-border: #2a2a30;
    --color-border-strong: #3a3a42;
    --color-input-bg: #141418;
    --color-toggle-off: #3a3a42;
    --color-toggle-knob: #e7e5e4;
    --color-green: #34d399;
    --color-red: #f87171;
    --color-seg-bg: #141418;
    --color-seg-active-bg: var(--color-accent);
    --color-seg-active-text: #ffffff;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: 'DM Sans', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--color-bg);
    color: var(--color-text);
    line-height: 1.5;
    padding: 2.5rem 1.25rem 3rem;
    max-width: 640px;
    margin: 0 auto;
    -webkit-font-smoothing: antialiased;
  }

  /* Header */
  .header-row {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 1.75rem;
  }
  h1 {
    font-size: 1.375rem;
    font-weight: 600;
    letter-spacing: -0.01em;
    margin-bottom: 0.25rem;
  }
  .subtitle {
    color: var(--color-text-secondary);
    font-size: 0.8125rem;
  }
  .theme-toggle {
    display: inline-flex;
    align-items: center;
    gap: 0.375rem;
    height: 30px;
    padding: 0 0.625rem;
    border: 1px solid var(--color-border);
    border-radius: 0.375rem;
    background: transparent;
    color: var(--color-text-secondary);
    font-family: inherit;
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: border-color 0.15s ease, color 0.15s ease;
    flex-shrink: 0;
  }
  .theme-toggle:hover { border-color: var(--color-accent); color: var(--color-accent); }

  /* Toggle switch — compact 40x22 */
  .toggle {
    position: relative;
    width: 40px; height: 22px;
    flex-shrink: 0;
  }
  .toggle input { opacity: 0; width: 0; height: 0; position: absolute; }
  .toggle .slider {
    position: absolute; inset: 0;
    background: var(--color-toggle-off);
    border-radius: 11px;
    cursor: pointer;
    transition: background 0.15s ease;
  }
  .toggle .slider::before {
    content: "";
    position: absolute;
    width: 16px; height: 16px;
    left: 3px; top: 3px;
    background: var(--color-toggle-knob);
    border-radius: 50%;
    transition: transform 0.15s ease;
  }
  .toggle input:checked + .slider { background: var(--color-accent); }
  .toggle input:checked + .slider::before { transform: translateX(18px); }

  /* Global toggle row */
  .global-toggle-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.875rem 0;
    border-bottom: 1px solid var(--color-border);
    margin-bottom: 1.25rem;
  }
  .global-toggle-row .global-label {
    font-weight: 600;
    font-size: 0.9375rem;
  }

  /* Events container */
  .events-container { transition: opacity 0.15s ease; }
  .events-container.disabled {
    opacity: 0.35;
    pointer-events: none;
  }

  /* Event section */
  .event-section {
    padding: 1rem 0;
    transition: opacity 0.15s ease;
  }
  .event-section + .event-section {
    border-top: 1px solid var(--color-border);
  }
  .event-section.disabled .event-controls { opacity: 0.35; pointer-events: none; }
  .event-header {
    display: flex;
    justify-content: space-between;
    align-items: flex-start;
    margin-bottom: 0.625rem;
  }
  .event-name {
    font-weight: 600;
    font-size: 0.8125rem;
    text-transform: uppercase;
    letter-spacing: 0.04em;
    color: var(--color-text);
  }
  .event-desc {
    color: var(--color-text-tertiary);
    font-size: 0.75rem;
    margin-top: 0.125rem;
  }

  /* Controls row */
  .event-controls {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
    transition: opacity 0.15s ease;
  }
  .controls-row {
    display: flex;
    align-items: center;
    gap: 0.625rem;
    flex-wrap: wrap;
  }

  /* Select */
  select {
    height: 32px;
    width: 120px;
    border: 1px solid var(--color-border);
    border-radius: 0.375rem;
    padding: 0 0.5rem;
    font-family: inherit;
    font-size: 0.8125rem;
    background: var(--color-input-bg);
    color: var(--color-text);
    cursor: pointer;
    transition: border-color 0.15s ease;
    -webkit-appearance: none;
    appearance: none;
    background-image: url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='10' height='6'%3E%3Cpath d='M0 0l5 6 5-6z' fill='%2378716c'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 8px center;
    padding-right: 1.5rem;
  }
  select:focus { outline: 2px solid var(--color-accent); outline-offset: -1px; }
  select:disabled { opacity: 0.35; cursor: default; }

  /* Volume slider */
  .volume-group {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    flex: 1;
    min-width: 120px;
    max-width: 200px;
  }
  input[type=range] {
    -webkit-appearance: none;
    appearance: none;
    width: 100%;
    height: 20px;
    background: transparent;
    cursor: pointer;
  }
  input[type=range]:disabled { opacity: 0.35; cursor: default; }
  input[type=range]::-webkit-slider-runnable-track {
    height: 4px;
    background: var(--color-border-strong);
    border-radius: 2px;
  }
  input[type=range]::-webkit-slider-thumb {
    -webkit-appearance: none;
    width: 14px; height: 14px;
    background: var(--color-accent);
    border-radius: 50%;
    margin-top: -5px;
    cursor: pointer;
    transition: transform 0.1s ease;
  }
  input[type=range]::-webkit-slider-thumb:hover {
    transform: scale(1.15);
  }
  input[type=range]::-moz-range-track {
    height: 4px;
    background: var(--color-border-strong);
    border-radius: 2px;
    border: none;
  }
  input[type=range]::-moz-range-thumb {
    width: 14px; height: 14px;
    background: var(--color-accent);
    border-radius: 50%;
    border: none;
    cursor: pointer;
  }
  .volume-val {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--color-text-secondary);
    min-width: 1.25rem;
    text-align: right;
    font-variant-numeric: tabular-nums;
  }

  /* Segmented control */
  .seg-control {
    display: inline-flex;
    border: 1px solid var(--color-border);
    border-radius: 0.375rem;
    overflow: hidden;
    height: 32px;
  }
  .seg-control label {
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 0 0.75rem;
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--color-text-secondary);
    cursor: pointer;
    background: var(--color-seg-bg);
    transition: background 0.15s ease, color 0.15s ease;
    user-select: none;
    border-right: 1px solid var(--color-border);
    white-space: nowrap;
  }
  .seg-control label:last-child { border-right: none; }
  .seg-control input { display: none; }
  .seg-control label.active {
    background: var(--color-seg-active-bg);
    color: var(--color-seg-active-text);
  }

  /* Sound-enabled + Preview row */
  .controls-row-secondary {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }
  .sound-toggle-group {
    display: flex;
    align-items: center;
    gap: 0.375rem;
    transition: opacity 0.15s ease;
  }
  .sound-toggle-group .speaker-icon {
    font-size: 0.875rem;
    color: var(--color-text-secondary);
    line-height: 1;
  }
  .sound-controls-dim { opacity: 0.35; }

  /* Preview button */
  .btn-preview {
    display: inline-flex;
    align-items: center;
    gap: 0.25rem;
    height: 28px;
    padding: 0 0.625rem;
    border: 1px solid var(--color-border);
    border-radius: 0.375rem;
    background: transparent;
    color: var(--color-text-secondary);
    font-family: inherit;
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: border-color 0.15s ease, color 0.15s ease;
  }
  .btn-preview:hover { border-color: var(--color-accent); color: var(--color-accent); }
  .btn-preview:disabled { opacity: 0.35; cursor: default; }
  .btn-preview:disabled:hover { border-color: var(--color-border); color: var(--color-text-secondary); }
  .btn-preview .play-icon { font-size: 0.625rem; }

  /* Save area */
  .save-area {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 0.75rem;
    margin-top: 1.5rem;
    padding-top: 1rem;
  }
  .btn-save {
    position: relative;
    height: 36px;
    padding: 0 1.25rem;
    background: var(--color-accent);
    color: #fff;
    border: none;
    border-radius: 0.375rem;
    font-family: inherit;
    font-size: 0.8125rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s ease, transform 0.1s ease;
  }
  .btn-save:hover { background: var(--color-accent-hover); }
  .btn-save:active { transform: scale(0.98); }
  .btn-save .dirty-dot {
    position: absolute;
    top: -3px; right: -3px;
    width: 8px; height: 8px;
    background: var(--color-accent);
    border: 2px solid var(--color-bg);
    border-radius: 50%;
    display: none;
  }
  .btn-save.has-changes .dirty-dot { display: block; }

  /* Toast */
  .toast {
    position: fixed;
    top: 1.25rem;
    right: 1.25rem;
    padding: 0.625rem 1rem;
    border-radius: 0.5rem;
    font-size: 0.8125rem;
    font-weight: 500;
    font-family: inherit;
    transform: translateY(-0.5rem);
    opacity: 0;
    transition: transform 0.2s ease, opacity 0.2s ease;
    pointer-events: none;
    z-index: 100;
  }
  .toast.show { transform: translateY(0); opacity: 1; }
  .toast.ok {
    background: var(--color-green);
    color: #fff;
  }
  .toast.err {
    background: var(--color-red);
    color: #fff;
  }

  /* Responsive */
  @media (max-width: 600px) {
    body { padding: 1.5rem 1rem 2rem; }
    .controls-row { flex-direction: column; align-items: stretch; gap: 0.5rem; }
    .controls-row > * { width: 100%; }
    select { width: 100%; }
    .volume-group { max-width: none; }
    .seg-control { width: 100%; }
    .seg-control label { flex: 1; }
    .controls-row-secondary { flex-direction: column; align-items: stretch; gap: 0.5rem; }
    .save-area { justify-content: stretch; }
    .btn-save { width: 100%; }
  }
</style>
</head>
<body>

<div class="header-row">
  <div>
    <h1>Claude Code Notifications</h1>
    <p class="subtitle">Configure sounds, volume, and alert styles.</p>
  </div>
  <button class="theme-toggle" onclick="toggleTheme()" id="theme-btn" title="Toggle dark/light theme"></button>
</div>

<div id="app">Loading...</div>
<div class="toast" id="toast"></div>

<script>
// Theme management
function getPreferredTheme() {
  const saved = localStorage.getItem('theme');
  if (saved) return saved;
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  const btn = document.getElementById('theme-btn');
  if (btn) btn.textContent = theme === 'dark' ? '\u2600 Light' : '\u263E Dark';
}
function toggleTheme() {
  const current = document.documentElement.getAttribute('data-theme');
  const next = current === 'dark' ? 'light' : 'dark';
  localStorage.setItem('theme', next);
  applyTheme(next);
}
applyTheme(getPreferredTheme());

const SOUNDS = %%SOUNDS%%;
const EVENT_META = %%EVENT_META%%;
const EVENT_ORDER = %%EVENT_ORDER%%;

let config = null;
let savedSnapshot = '';
let isDirty = false;

async function loadConfig() {
  const res = await fetch('/api/config');
  config = await res.json();
  savedSnapshot = JSON.stringify(config);
  isDirty = false;
  render();
}

function markDirty() {
  isDirty = JSON.stringify(config) !== savedSnapshot;
  const btn = document.querySelector('.btn-save');
  if (btn) btn.classList.toggle('has-changes', isDirty);
}

function getEventVal(key, field) {
  const evt = (config.events || {})[key] || {};
  if (field === 'enabled') return evt.enabled !== undefined ? evt.enabled : true;
  if (field === 'sound') return evt.sound || 'Funk';
  if (field === 'volume') return evt.volume !== undefined ? evt.volume : 7;
  if (field === 'style') return evt.style || 'persistent';
  if (field === 'sound_enabled') return evt.sound_enabled !== undefined ? evt.sound_enabled : true;
  return undefined;
}

function setEventVal(key, field, value) {
  if (!config.events) config.events = {};
  if (!config.events[key]) config.events[key] = {};
  config.events[key][field] = value;
  markDirty();
}

function toggleGlobal(checked) {
  config.global_enabled = checked;
  markDirty();
  render();
}

function render() {
  const app = document.getElementById('app');
  const globalOn = config.global_enabled !== undefined ? config.global_enabled : true;
  let html = '';

  // Global toggle row
  html += `<div class="global-toggle-row">
    <span class="global-label">Enable Notifications</span>
    <label class="toggle">
      <input type="checkbox" ${globalOn?'checked':''} onchange="toggleGlobal(this.checked)">
      <span class="slider"></span>
    </label>
  </div>`;

  // Events container
  html += `<div class="events-container ${globalOn?'':'disabled'}">`;

  for (const key of EVENT_ORDER) {
    const meta = EVENT_META[key] || {label: key, description: ''};
    const enabled = getEventVal(key, 'enabled');
    const sound = getEventVal(key, 'sound');
    const volume = getEventVal(key, 'volume');
    const style = getEventVal(key, 'style');
    const soundOn = getEventVal(key, 'sound_enabled');
    const soundCtrlOff = !enabled || !soundOn;

    html += `<div class="event-section ${enabled?'':'disabled'}" id="evt-${key}">
      <div class="event-header">
        <div>
          <div class="event-name">${meta.label}</div>
          <div class="event-desc">${meta.description}</div>
        </div>
        <label class="toggle">
          <input type="checkbox" ${enabled?'checked':''} onchange="toggleEvent('${key}',this.checked)">
          <span class="slider"></span>
        </label>
      </div>
      <div class="event-controls">
        <div class="controls-row">
          <select id="sound-${key}" onchange="setEventVal('${key}','sound',this.value)" ${soundCtrlOff?'disabled':''}>
            ${SOUNDS.map(s => `<option value="${s}" ${s===sound?'selected':''}>${s}</option>`).join('')}
          </select>
          <div class="volume-group ${soundCtrlOff?'sound-controls-dim':''}">
            <input type="range" id="vol-${key}" min="1" max="20" value="${volume}" ${soundCtrlOff?'disabled':''}
              oninput="setEventVal('${key}','volume',+this.value);this.nextElementSibling.textContent=this.value">
            <span class="volume-val">${volume}</span>
          </div>
          <div class="seg-control" id="style-${key}">
            <label class="${style==='persistent'?'active':''}"
              onclick="if(!this.closest('.event-section').classList.contains('disabled')){setRadio('style-${key}','persistent');setEventVal('${key}','style','persistent')}">
              <input type="radio" name="style-${key}" value="persistent" ${style==='persistent'?'checked':''} ${enabled?'':'disabled'}><span>Persistent</span>
            </label>
            <label class="${style==='banner'?'active':''}"
              onclick="if(!this.closest('.event-section').classList.contains('disabled')){setRadio('style-${key}','banner');setEventVal('${key}','style','banner')}">
              <input type="radio" name="style-${key}" value="banner" ${style==='banner'?'checked':''} ${enabled?'':'disabled'}><span>Banner</span>
            </label>
          </div>
        </div>
        <div class="controls-row-secondary">
          <div class="sound-toggle-group">
            <span class="speaker-icon">${soundOn ? '\uD83D\uDD0A' : '\uD83D\uDD07'}</span>
            <label class="toggle">
              <input type="checkbox" ${soundOn?'checked':''} ${enabled?'':'disabled'} onchange="setEventVal('${key}','sound_enabled',this.checked);render()">
              <span class="slider"></span>
            </label>
          </div>
          <button class="btn-preview" onclick="previewEvt(this,'${key}')" ${enabled?'':'disabled'}><span class="play-icon">&#9654;</span> Preview</button>
        </div>
      </div>
    </div>`;
  }

  html += `</div>`; // close events-container

  html += `<div class="save-area">
    <button class="btn-save ${isDirty?'has-changes':''}" onclick="saveConfig()">Save Settings<span class="dirty-dot"></span></button>
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

async function preview(sound, volume, style, eventKey, soundEnabled) {
  const se = soundEnabled !== undefined ? soundEnabled : true;
  await fetch('/api/preview', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({sound, volume, style, event_key: eventKey || null, sound_enabled: se}),
  });
}

async function previewEvt(btn, key) {
  const origText = btn.innerHTML;
  btn.innerHTML = '<span class="play-icon">&#8987;</span> ...';
  btn.disabled = true;
  try {
    await preview(getEvtSound(key), getEvtVol(key), getEventVal(key,'style'), key, getEventVal(key,'sound_enabled'));
  } finally {
    setTimeout(() => { btn.innerHTML = origText; btn.disabled = false; }, 400);
  }
}

function showToast(message, type) {
  const toast = document.getElementById('toast');
  toast.textContent = message;
  toast.className = 'toast ' + type;
  requestAnimationFrame(() => { toast.classList.add('show'); });
  setTimeout(() => { toast.classList.remove('show'); }, 2500);
}

async function saveConfig() {
  try {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify(config),
    });
    if (!res.ok) throw new Error(await res.text());
    savedSnapshot = JSON.stringify(config);
    isDirty = false;
    const btn = document.querySelector('.btn-save');
    if (btn) btn.classList.remove('has-changes');
    showToast('Settings saved', 'ok');
  } catch (e) {
    showToast('Error: ' + e.message, 'err');
  }
}

// Keyboard shortcut: Cmd+S / Ctrl+S to save
document.addEventListener('keydown', (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === 's') {
    e.preventDefault();
    saveConfig();
  }
});

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
"elicitation_dialog": "Claude Code - Action Required",
    "stop": "Claude Code - Done",
}

PREVIEW_BODIES = {
    "permission_request": "Approve: Bash (preview)",
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
                for k in list(data.keys()):
                    if k.startswith("default_"):
                        del data[k]
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

                sound_enabled = data.get("sound_enabled", True)

                # Send macOS notification via the appropriate notifier app
                _send_preview_notification(style, event_key)

                # Play alert sound (if sound is enabled)
                if sound_enabled:
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
