---
name: msx-observe
description: Capture the current MSX screen and read that exact image, preserving its frame and artifact reference. Use when identifying a game prompt, date, menu, or visible change.
---

Call `keeper_compose_msx-observe` with a focused `query` about visible text or
pixels. The composition captures once, then passes the exact artifact handle
to the vision reader without copying it through model output. It sends no game
input and leaves vision runtime selection automatic.

Read the capture result's `frame` and `artifact` alongside the reader's answer
in the returned actions. The answer describes that captured snapshot: another
player or spectator may advance the machine during analysis. A successful
reading does not establish driving ownership or make uncertain text certain.
After further game input, capture again before confirming the current state.
If the reader fails, retain the capture evidence and report the reading failure.

```toml composition
[[compositions]]
name = "msx-observe"
description = "Capture the MSX screen and read its exact image with frame provenance."
execution = "inline"

[[compositions.params]]
name = "query"
type = "string"
description = "A focused question about visible text or pixels. Request unreadable characters be marked rather than inferred."

[[compositions.nodes]]
id = "capture"
tool = "masc_msx_screen"
[compositions.nodes.input]
kind = "literal"
value = {}

[[compositions.nodes]]
id = "read"
tool = "keeper_analyze_image"
[compositions.nodes.input]
kind = "object"

[[compositions.nodes.input.fields]]
name = "artifact"
[compositions.nodes.input.fields.value]
kind = "output"
node = "capture"
pointer = "/artifact"

[[compositions.nodes.input.fields]]
name = "query"
[compositions.nodes.input.fields.value]
kind = "param"
name = "query"
```
