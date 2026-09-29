# TUI wiring follow-up — 2026-09-29

Scope: the portrait (#39883), chat input/slash menu (#39890), and loading-error
inspection (#39899) candidates initially audited against main
`cbe8e58d6676bc8dda1f83c64b16c4f33e7884fb`, then integrated with main
`3cbca7f56e` after #39899 and the stream-line scanner #39909 landed. This is a bounded source/interaction
audit, not a claim about every repository feature or the installed Ghostty binary.

## Findings

1. **Hidden roster still owned keyboard focus.** Wide chat could retain
   `Left_pane` after resize hid its roster. Arrow/Enter handling then still
   addressed the invisible list, and the composer cursor stayed hidden.
   This already existed on main; the new automatic chat roster makes the path
   more relevant. The correction reconciles focus with actual available columns
   before input dispatch and rendering, including explicit hiding.
2. **Play subcommands were absent from the picker.** The catalog, parser,
   HTTP handlers and callbacks were connected, so manual `/play` commands
   worked, but `known_sub_arguments` omitted the family. The picker now offers
   `invites`, `invite`, `link`, and `revoke`. Acceptance still only fills the
   draft; explicit arguments and a further Enter are required for execution.
3. **The Play PTY's claimed local-only behavior was under-asserted.** It counted
   expected admin requests but did not reject Keeper or tool calls. Its effect
   check now rejects unexpected requests and verifies picker acceptance makes
   no Play API call.

## Traced paths

| Surface | Producer to consumer | Finding |
|---|---|---|
| Portrait | `bin/dune` module -> `Chat.prepare` -> chat renderer -> portrait request/flush/delete -> native and PTY aliases | Connected. Conversation owner, not roster cursor, selects the image. |
| Roster preference | `Auto/Hidden/Shown` -> effective width/visibility -> key handling and renderer | Hidden-focus defect above; explicit preference survives navigation and resize. |
| Slash menu | catalog/parser -> menu window -> select/accept -> dispatcher -> renderer/footer | Play discovery omission above; Esc precedence and two-stage acceptance preserved. |
| `/errors` | interface/catalog/parser -> chat/composer dispatch -> current errors -> terminal-safe local notice -> PTY alias | Connected; target-change cache reset prevents old errors appearing under another Keeper. |
| Play effects | typed parser -> GET/POST/DELETE helpers -> registered authenticated server routes -> async callback | Connected; callback retains original Keeper, and refused/unknown results stay distinct. |
| Runtime lane order | both edit callers -> expected candidates -> same raw-config read's source revision -> routing write -> notice/reload | Connected; stale candidate order is rejected. |
| Preset read errors | `unreadable_rows` -> existing scrollable preset detail pane | Connected after wrapping change. |
| Goal owner moved off Overview | typed Goal data -> Planning detail owner row; fixed row budget updated | Owner display retained in Planning. Overview's removed progress/metadata rows are not dangling callbacks. |

At the initial audit, a direct PR-head vs main comparison made PR-only
`/errors` and portrait files appear deleted. Common-ancestor diffs showed
these were additions absent from main, not removals. #39899 has since merged;
the remaining candidates include that integration.
Home #39817 is a separate pending change; its navigation/default assumptions
must be checked again when it is integrated.

## Evidence and limits

Prior focused CI passed portrait placement/regions, input/menu/keyboard, and
full loading-error inspection including a gated Keeper switch. The two new
wiring fixes have syntax/source checks and dedicated regression scenarios;
their integrated native/PTY results must be recorded before calling them
runtime-verified. No local native build or installed-TUI restart was performed.

PNG retransmission is measured in `test_tui_chat_portrait_pty`: while
typing, and through a held running turn (motion steps, then a streamed
reply), no unchanged portrait pixels may travel unless the frame cleared the
screen. A put by image id (`a=p`) over a rewritten row is counted and allowed.
