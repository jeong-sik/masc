---
name: dos-observe
description: Read the DOS world's counter, captured screen, action receipt and incarnation before deciding whether another input is useful.
---

Use this Skill when a DOS world Lane is installed and its captures or actions are
relevant to your current work. Continue your other work if its observation is
pending or unavailable. Reading this Skill does not send input to the machine.

The package owns a small homebrew DOS program. Its `increment` action sends the
N key. A confirmed receipt means the guest STATE.BIN counter and the corresponding
green bar were both observed. It does not prove progress in another DOS game.

Read the exact installed instance and incarnation from current Lane inspection.
Use the host's existing Lane action tool when you choose to act. Reuse a request ID
only for the same request to the same incarnation. An unknown outcome calls for
inspection; sending a new request is another action, not a harmless retry.

Inspect `references/state-format.md` through the existing `keeper_skill` resource
reader for byte and clock semantics. `scripts/read-state.mjs` reads a retained
STATE.BIN artifact from a local file and reports its header, counter and SHA-256.
It takes one explicit path and cannot connect to or control a DOS machine. Run it
only through an existing authorized execution tool if that helps your task.

Capture sequence counts delivered screen captures, not emulated frames or turns.
The guest counter is a uint16 count modulo 65536. Evidence applies to its exact
machine incarnation. A replacement worker starts a new machine; previous
artifacts remain historical evidence rather than its current state.
