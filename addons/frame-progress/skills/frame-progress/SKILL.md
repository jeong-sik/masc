---
name: frame-progress
description: Interpret MSX observed frame progress rows and select their two original capture references without confusing frames with game success.
---

Use this Skill when inspecting a frame-progress Lane or deciding whether its
observations help the current task. Read the selected row's `fields.state`,
`fields.value`, `fields.reason`, `fields.current` and `fields.previous` together.

- `measured` describes the difference between two supplied MSX captures. Keep
  their producer installation, instance, revisions, cursors and machine clock.
  Unchanged input count does not imply an unchanged frame.
- `baseline` has no measured difference. A restart, restore or producer change
  requires a new complete pair. Do not substitute zero for null.
- `unknown` or incomplete coverage does not establish that the game stopped.
  Keep the missing-input or discontinuity reason. Existing work can continue.

The calculation clears a baseline for unavailable or invalid capture data in a
valid source envelope. A malformed protocol request rejected before observation
does not transition that baseline; a request error is not a new measurement.

When forwarding a measurement to a Keeper, select the row and its retained
evidence through the existing Lane Slice path. Both original captures and
their screenshot/output references are available under `previous` and
`current`. A screen interpretation requires inspecting the referenced bytes;
the numeric frame difference alone does not establish game turns, strategy,
score or a winner. Repeated rows can describe the same interval: never sum
their values as a cumulative counter.

This package only reads supplied observations. It does not control MSX, restore
the machine, approve actions or require the Keeper to consume its results.
Continue game actions through the existing owner and tools if the current task
calls for them. A baseline lives only in this worker; historical rows do not
prove restart-continuous measurement.
