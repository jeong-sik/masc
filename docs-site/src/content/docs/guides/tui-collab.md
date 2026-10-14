---
title: TUI Collab Hub
description: Shared MSX and DOS observation, F5 control toggle, play links, and public chat.
---

## (a) Overview / 한 줄 요약

The TUI Collab hub provides zero-Keeper shared MSX and DOS screen observation, explicit `F5` game control toggling, DOS spectator play invite issuing and revocation, and shared public conversation in a unified spectator window.

TUI Collab 허브는 별도 Keeper 선택 없이 공유 MSX/DOS 화면을 관측하고, `F5` 키로 MSX 게임 제어권을 전환하며, DOS 공개 플레이 초대 링크 발급·회수 및 관측자 공개 채팅을 한 화면에서 수행하는 통합 협업 제어 허브입니다.

---

## (b1) Enabling: Settings & Entry Keys / 켜는 법: 설정 이름

The Collab hub is built into `masc-tui` and accessed directly from the terminal interface:

- **Hub Entry**: Press `&` in normal mode, or type `:` then `go Collab` in the command bar.
- **Direct Machine Views**: Press `m` for MSX, `d` for DOS, or `:` then `go MSX` / `go DOS`.
- **MSX Control Toggle**: In the MSX view, press `F5` to toggle between `Observation` and `Control`.
- **Machine Switching**: In the shared spectator view, press `F4` to cycle between MSX and DOS without losing draft text or spectator presence.
- **Public Chat Focus**: In the Collab spectator view, press `Tab` to switch focus between the machine frame and the public chat composer.
- **Play Invites**: In Collab, press `n` to issue a new player invite (prompts for player name and expiry hours), `x` to revoke the selected invite, and `r` to refresh the inventory.

### Key Code & Module Coordinates
- `bin/masc_tui_collab.ml` / `bin/masc_tui_collab.mli`: Collab hub state machine and layout rendering.
- `bin/masc_tui_keys.ml`: Navigation key bindings (`&`, `F5`, `F4`, `Tab`).
- `bin/masc_tui_types.ml`: `Collab_focus` (`Spectator` | `Conversation` | `PlayInvites`).
- `bin/masc_tui_play_pending.ml`: Journaling durable invite intents before dispatch (`.masc/tui-play-pending.jsonl`).

---

## (b2) Activation Conditions & Fail-Closed Behavior / 켜지는 조건과 실패 증상

### Conditions
- **Observation by Default**: Entering Collab or switching games always resets the controller to safe `Observation` mode. No keystrokes are forwarded to the game engine until `F5` is explicitly pressed.
- **Workspace Authority Binding**: All invite modifications (`issue`, `revoke`) and game control dispatches require the server to verify and match the TUI's local workspace (`expected_base_path` and `expected_masc_root`).

### Failure Symptoms & Recovery
- **Identity Unread / Unconfirmed (Fail-Closed)**: If the local workspace identity cannot be confirmed by the server, the machine view closes, game control is cleared, and invite mutation requests are blocked.
- **Unknown Outcome Quarantine**: If an invite issue or revoke request is disconnected before the server response arrives, the outcome remains explicitly `unknown`. The TUI logs the request to `.masc/tui-play-pending.jsonl`.
- **Unlocking Unknown Outcomes (`u` key)**: When an unknown outcome is recorded, further invite creation is locked. The operator must inspect the server logs or confirm that the server process stopped, open Collab, press `u`, and confirm the check to unlock subsequent mutations.
- **Conversation Polling Suspension**: Public spectator room polling stops when workspace identity is unconfirmed to prevent ghost presence.

---

## (c) Runnable Examples / 실행 예시

### 1. Launching MASC TUI
```bash
# Build the TUI binary from source
dune build --root . bin/masc_tui.exe

# Start the TUI pointing to your workspace and server port
./_build/default/bin/masc_tui.exe --base-path ~/masc --port 8935
```

### 2. Interactive Navigation Sequence
1. Press `&` to open the Collab hub.
2. Press `m` to watch the active MSX screen.
3. Observe the mode badge in the status bar (initially `[Observation]`).
4. Press `F5` to enable input forwarding (badge flips to `[Control]`). Directional keys and action buttons now drive the MSX machine.
5. Press `F4` to switch to the DOS spectator view.
6. Press `Tab` to jump focus into the chat input bar, type a message, and press `Enter`.
7. Press `Esc` to return to the Collab overview menu.
8. Press `n`, type a player nickname (e.g. `guest1`) and expiry hours (e.g. `12`), then press `Enter` to generate a spectator QR and play link.

---

## (d) Disabling & Reverting / 끄는 법 및 되돌리는 법

- **Release Control**: Press `F5` in the MSX view to return immediately to `Observation` mode.
- **Exit View**: Press `Esc` to leave the active machine screen and return to Collab; press `q` or `Esc` in Collab to return to the primary TUI surface.
- **Revoke Invite**: Highlight the invite in Collab and press `x`, or execute `/play revoke <name>` from the TUI command bar.

---

## (e) Experimental Status & Known Limitations / 실험 표시 및 알려진 한계

- **Status**: Stable in v0.52.0+; relies on local loopback or authenticated reverse proxy for remote guests.
- **Single Active Controller**: Only one player or Keeper may hold the machine controller at any given moment. Spectators can watch the frame updates in real-time but cannot inject inputs while another entity holds the controller.
- **Terminal Width Constraints**: On narrow terminals (under 80 columns), public chat messages may be truncated or compact mode will hide conversational sidebars to preserve game frame aspect ratios.
- **Offline Confirmation Requirement**: Lost network acknowledgements for invites must be cleared via the `u` confirmation workflow; simply restarting the TUI will not bypass an unresolved `.masc/tui-play-pending.jsonl` entry.
