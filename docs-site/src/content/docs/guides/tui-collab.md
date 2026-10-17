---
title: TUI Collab Hub
description: Shared MSX and DOS observation, MSX cartridge loading, F5 control toggle, DOS play invites, and public chat.
---

## Overview

The TUI Collab hub provides shared MSX and DOS screen observation without requiring a selected Keeper, an MSX cartridge load menu (`g`), explicit `F5` MSX game control toggling, DOS play invite issuing and revocation (`n` / `/play invite`), and shared public conversation in a unified window.

---

## Enabling: Settings & Entry Keys

The Collab hub is built into `masc-tui` and accessed directly from the terminal interface:

- **Hub Entry**: Press `&` in normal mode, or type `:` then `go Collab` in the command bar.
- **Direct Machine Views (`m` / `d`)**: Press `m` to watch the shared MSX machine or `d` to watch the shared DOS machine (or `:` then `go MSX` / `go DOS`).
- **MSX Cartridge Load Menu (`g`)**: In Collab, press `g` to open the MSX cartridge load menu listing ROM images in `<base-path>/.masc/msx/carts/`, then watch or play the loaded game.
- **MSX Control Toggle (`F5`)**: In the MSX view, press `F5` to toggle between `Observation` and `Control`.
- **Machine Switching (`F4`)**: In the shared spectator view, press `F4` to cycle between MSX and DOS without losing draft text or spectator presence.
- **Public Chat Focus (`Tab`)**: In the Collab spectator view, press `Tab` to switch focus between the machine frame and the public chat composer.
- **DOS Play Invites (`n` / `/play invite`)**: In Collab, press `n` (or run `/play invite <name> <hours>` in chat) to issue a new DOS player invite, `x` to revoke the selected invite, and `r` to refresh the inventory. Invited guests and external AI agents can view and control the shared DOS machine in a browser via `/play#<token>` or over MCP at `/mcp/play` (instructions served at `/play/agent.md`).

### Key Code & Module Coordinates
- `bin/masc_tui_collab.ml` / `bin/masc_tui_collab.mli`: Collab hub state machine and layout rendering.
- `bin/masc_tui_keys.ml`: Navigation key bindings (`&`, `g`, `m`, `d`, `F5`, `F4`, `Tab`).
- `bin/masc_tui_types.ml`: `Collab_focus` (`Spectator` | `Conversation` | `PlayInvites`).
- `bin/masc_tui_play_pending.ml`: Journaling durable invite intents before dispatch (`.masc/tui-play-pending.jsonl`).

---

## Activation Conditions & Fail-Closed Behavior

### Conditions
- **Observation by Default**: Entering Collab, opening the `g` cartridge picker, or switching games always resets the controller to safe `Observation` mode. No keystrokes are forwarded to the game engine until `F5` is explicitly pressed.
- **Workspace Authority Binding**: All invite modifications (`issue`, `revoke`) and game control dispatches require the server to verify and match the TUI's local workspace (`expected_base_path` and `expected_masc_root`).

### Failure Symptoms & Recovery
- **Identity Unread / Unconfirmed (Fail-Closed)**: If the local workspace identity cannot be confirmed by the server, the machine view closes, game control is cleared, and invite mutation requests are blocked.
- **Unknown Outcome Quarantine**: If an invite issue or revoke request is disconnected before the server response arrives, the outcome remains explicitly `unknown`. The TUI logs the request to `.masc/tui-play-pending.jsonl`.
- **Unlocking Unknown Outcomes (`u` key)**: When an unknown outcome is recorded, further invite creation is locked. The operator must inspect the server logs or confirm that the server process stopped, open Collab, press `u`, and confirm the check to unlock subsequent mutations.
- **Conversation Polling Suspension**: Public spectator room polling stops when workspace identity is unconfirmed to prevent ghost presence.

---

## Runnable Examples

### 1. Launching MASC TUI
```bash
# Start the TUI pointing to your workspace and server port
masc-tui --base-path ~/masc --port 8935
```

### 2. Interactive Navigation Sequence
1. Press `&` to open the Collab hub.
2. Press `g` to open the MSX cartridge load menu (or `m` / `d` to switch directly to the active MSX or DOS machine screen).
3. Observe the mode badge in the status bar (initially `[Observation]`).
4. In MSX, press `F5` to enable input forwarding (badge flips to `[Control]`). Directional keys and action buttons now drive the MSX machine.
5. Press `F4` to switch between the MSX and DOS views.
6. Press `Tab` to jump focus into the chat input bar, type a message, and press `Enter`.
7. Press `Esc` to return to the Collab overview menu.
8. Press `n`, type a player nickname (e.g. `guest1`) and expiry hours (e.g. `12`), then press `Enter` to generate a one-time QR card and play link (`/play#<token>`, with MCP access at `/mcp/play`).

---

## Disabling & Reverting

- **Release Control**: Press `F5` in the MSX view to return immediately to `Observation` mode.
- **Exit View**: Press `Esc` to leave the active machine screen and return to Collab; press `q` or `Esc` in Collab to return to the primary TUI surface.
- **Revoke Invite**: Highlight the invite in Collab and press `x`, or execute `/play revoke <name>` from the TUI command bar.

---

## Status & Known Limitations

- **Status**: Stable in v0.52.0+; relies on local loopback or an authenticated reverse proxy (`MASC_HTTP_BASE_URL`) for remote guests.
- **Single Active Controller**: Only one player or Keeper may hold the machine controller at any given moment. Spectators can watch frame updates but cannot inject inputs while another participant holds the controller.
- **Terminal Width Constraints**: On narrow terminals (under 80 columns), public chat messages may be truncated or compact mode will hide conversational sidebars to preserve game frame aspect ratios.
- **Offline Confirmation Requirement**: Lost network acknowledgements for invites must be cleared via the `u` confirmation workflow; restarting the TUI does not bypass an unresolved `.masc/tui-play-pending.jsonl` entry.
