---
name: sangokushi-2-end-command
description: "Sends the observed Sangokushi II province-command end sequence (0, Return, y), waits for screen settling and returns the observation. Use only at the province (0-19)? prompt while authorized to drive the shared machine. Inspect the returned image: screen settling does not prove province completion or month progression. If another driver intervened or the result is uncertain, observe the current state before choosing further input; do not replay the sequence automatically."
---

# Sangokushi II: end the province's commands

The verified province-command end for Sangokushi II, observed as the province
10 to 18 transition. One call presses `0`, Return, `y` in sequence, advances
until the screen settles (`masc_msx_step_until_change`), and returns the
settled observation with its frame and artifact.

Use it only when the visible prompt is the province command prompt of the
province you are finishing; a macro pressed on another screen is just keys.
The game knowledge this macro comes from — menus, save flow, media pitfalls —
lives in the `sangokushi-2` Skill. The machine is shared: an unexpected
result may mean another driver intervened between the presses and the settle;
re-observe before retrying (the `msx-play` Skill, shared machine).

```toml composition
[[compositions]]
name = "sangokushi-2-end-command"
description = "Sends the observed Sangokushi II province-command end sequence (0, Return, y), waits for screen settling and returns the observation. Use only at the province (0-19)? prompt while authorized to drive the shared machine. Inspect the returned image: screen settling does not prove province completion or month progression. If another driver intervened or the result is uncertain, observe the current state before choosing further input; do not replay the sequence automatically."
execution = "inline"

[[compositions.nodes]]
id = "press"
tool = "masc_msx_press"
[compositions.nodes.input]
kind = "object"

[[compositions.nodes.input.fields]]
name = "keys"
[compositions.nodes.input.fields.value]
kind = "literal"
value = ["0", "Return", "y"]

[[compositions.nodes.input.fields]]
name = "sequence"
[compositions.nodes.input.fields.value]
kind = "literal"
value = true

[[compositions.nodes]]
id = "settle"
tool = "masc_msx_step_until_change"
after = ["press"]
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "screen"
tool = "masc_msx_screen"
after = ["settle"]
[compositions.nodes.input]
kind = "literal"
value = {}
```
