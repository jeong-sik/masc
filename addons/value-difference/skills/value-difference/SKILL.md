---
name: value-difference
description: Read signed changes between supplied numeric observations with their original values, clocks, cursors and evidence.
---

Use this Skill when a value-difference Lane may help the current task. Read
`fields.state`, `field`, `unit`, `value`, `direction`, `previous` and `current`
together. The selected field is an exact row field; its unit is explicitly
configured. Do not infer game score, frames or elapsed time from another value.

- `measured` means current minus previous. `up` and `down` describe its sign;
  neither means good or bad. `unchanged` means the two supplied values agree.
- `baseline` has a complete first sample but no measured change. Null is not zero.
- `unknown` or missing rows mean a value cannot currently be derived. Preserve
  the reason and source coverage. They do not establish that the environment
  stopped, nor require existing work to wait.

A validated, noncontradictory incomplete observation does not replace the last
complete endpoint. A later measurement can span that gap; inspect
`intervening_input_gap` and `last_input_gap` with both endpoints. The latter is
the latest incomplete acquisition and its evidence, not a complete interval
history. Its `acquired_at` is distinct from the source row's observation time
and world clock. Recovery at the same endpoint keeps the earlier row unchanged;
the pending gap belongs to the next new endpoint's interval, not the old one.
Missing/malformed inputs, changed identity or inconsistent cursors
clear the comparison point instead.

Both original rows and their actors, clocks, producer installation and revisions,
source cursors and evidence appear in `previous` and `current`. Select these
through the existing Lane Slice/evidence path when forwarding the observation.
The calculation does not inherit the source actor or assert a causal relation.

Repeated observations can describe the same interval; do not sum them. Producer
notifications may be coalesced, and one action may trigger multiple samples.
Describe a sampled change between the recorded endpoints, not a complete event
history or a long-term trend. Negative differences are valid decreases.

Worker restart, changed identity/configuration or missing input requires a new
pair. Two finite values can have a nonfinite difference; that result is unknown
and resets the baseline. Existing retained rows do not prove continuous state
across that gap or restart. Baselines are local worker memory.

This optional package reads observations only. Continue actions through the
existing Keeper/controller tools and authority. Attaching, ignoring or removing
this metric never creates an obligation to review it before continuing work.
