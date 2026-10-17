---
title: Browser Lane BiDi Auto-Start
description: Automatic startup of Keeper Firefox and WebDriver BiDi host via runtime.toml configuration.
---

## Overview

With `[browser.live.bidi]` configured in `runtime.toml`, the MASC server automatically spawns the Keeper Firefox instance with WebDriver BiDi enabled and attaches the BiDi host as detached daemon processes, eliminating manual multi-terminal launch steps.

---

## Enabling: Configuration & CLI

### 1. Direct TOML Configuration
Edit `<base-path>/.masc/config/runtime.toml`:

```toml
[browser.live]
enabled = true

[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"  # Absolute path to Firefox binary
profile = "/Users/you/masc-keeper-firefox-profile"           # Dedicated profile directory
port = 9222                                                 # Optional, default 9222
```

### 2. CLI Setup Tool (`masc browser-lane-setup`)
Alternatively, configure the table and install host wrappers automatically using the CLI setup command:

```bash
masc browser-lane-setup --mode bidi \
  --firefox "/Applications/Firefox.app/Contents/MacOS/firefox" \
  --profile "/Users/you/masc-keeper-firefox-profile" \
  --port 9222
```
*Note: If `[browser.live.bidi]` already exists, `browser-lane-setup --mode bidi` preserves keys you do not pass, while `--firefox`, `--profile`, and `--port` update the key they name.*

### Key Code & Module Coordinates
- `lib/browser_keeper_firefox.ml` / `lib/browser_keeper_firefox.mli`: Spawn logic for Firefox with `--no-remote --remote-debugging-port`.
- `lib/browser_host/browser_host.ml`: BiDi host launcher and process lock management.
- `lib/browser_bidi_peer.ml`: WebDriver BiDi peer connection and profile verification.
- `lib/browser_bidi_host_status.ml`: `bidiHost` status reporting (`masc_starts`, `lane_off`, `not_configured`, `not_known`).

---

## Activation Conditions & Diagnostic Lifecycle

### Conditions
- **Server Startup Launch**: When MASC boots, if `[browser.live.bidi]` is present and `[browser.live] enabled = true`, the server inspects the configured port. If the port does not answer, it spawns Firefox and the BiDi host.
- **On-Demand Auto-Recovery**: If Firefox or the host terminates during operation, an incoming Keeper `hover_at` or `drag` tool call detects the missing connection and initiates a single-flight startup sequence.
- **Detached Process Lifecycle**: Both Firefox and the host run in independent process groups (`Posix_spawn_detached`). Server restarts and deploys leave the Keeper browser window open and active.

### Failure Symptoms & Diagnostics
- **Start Audit Journal**: Every startup attempt is recorded in `.masc/browser-lane/keeper-firefox-start.json` with timestamp, port, profile path, and outcome status.
- **Log Files**:
  - Firefox output: `.masc/browser-lane/keeper-firefox.log` (rotated to `keeper-firefox.log.1` on each new run).
  - BiDi host output: `.masc/browser-lane/bidi-host.log` (rotated to `bidi-host.log.1`).
- **Profile Lock Conflict**: Firefox refuses multiple instances on the same profile directory. If another Firefox instance already holds the profile, the new process exits with status 0 immediately, and the port wait times out after 30 seconds.
- **Host Lock Conflict**: If a host already holds the lock on the specified port (`Host_running` or `Host_address_unknown`), the server will not launch a competing host.
- **TUI & Doctor Reporting**:
  - `masc doctor` reports whether MASC manages the browser and identifies recent failures.
  - The TUI Browser Lane picker displays the `bidiHost` status: `masc_starts` (with port and profile), `lane_off`, or `not_configured`.

---

## Runnable Examples

### 1. Initialize Profile & Configuration
```bash
# Create an isolated Firefox profile directory
mkdir -p "$HOME/.masc/browser-lane/firefox-profile"

# Append configuration to runtime.toml (expands $HOME to match the directory above)
cat << EOF >> .masc/config/runtime.toml

[browser.live]
enabled = true

[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "$HOME/.masc/browser-lane/firefox-profile"
port = 9222
EOF
```

### 2. Launch Server and Verify
```bash
# Start MASC server
masc start --base-path . --port 8935

# In another terminal, inspect diagnostics
masc doctor --base-path .

# Inspect start audit receipt
cat .masc/browser-lane/keeper-firefox-start.json

# Check live host logs
tail -n 20 .masc/browser-lane/bidi-host.log
```

---

## Disabling & Reverting

- **Disable in Config**: Remove or comment out `[browser.live.bidi]`, or set `[browser.live] enabled = false` in `runtime.toml`. The server will no longer spawn browser processes.
- **Terminate Running Daemons**:
  ```bash
  # Terminate detached processes if running
  pkill -f "firefox.*--remote-debugging-port 9222"
  pkill -f "masc[-_]browser[-_]host.*--bidi-url"
  ```
- **Revert to Manual Host**: Start Firefox manually with `--remote-debugging-port 9222` and launch `masc-browser-host --bidi-url ws://127.0.0.1:9222/session`.

---

## Status & Known Limitations

- **Status**: Introduced in v0.52.0. Requires Firefox 157.0.1+ with Remote Agent support.
- **Dedicated Profile Invariant**: You **must** supply a dedicated profile path. Using your everyday default profile will fail if your personal browser is already running (`--firefox-profile` guard).
- **Loopback Enforcement**: The WebSocket BiDi URL is strictly constrained to loopback (`127.0.0.1`); remote non-local hosts are rejected for security.
