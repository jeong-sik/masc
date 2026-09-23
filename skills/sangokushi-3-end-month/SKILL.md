---
name: sangokushi-3-end-month
description: "One call to end the current ruler's month in 삼국지 III (0, enter, y): presses the observed sequence and returns the settled screen with its PNG. Use only at a <군주>님 …에 명령을(0-9)? prompt of your own ruler."
---

# 삼국지 III: end the month

Presses `0`, `enter`, `y` — 휴양 as the last command, then yes to
이달의 명령을 끝내겠습니까(Y/N)? — and returns the screen the machine settles
on, which is usually the next human ruler's command prompt after the AI
rulers have moved. If `keys_pressed` is below 3 or `settled` is false, the AI
turns are still running: `masc_dos_step` before reading.

Use it only when the prompt names your own ruler. The game knowledge is in
the `sangokushi-3` Skill; passing the controller to the next player is in
`dos-play`.

```toml composition
[[compositions]]
name = "sangokushi-3-end-month"
description = "End the current ruler's month (0, enter, y) and return the settled screen."
execution = "inline"

[[compositions.nodes]]
id = "press"
tool = "masc_dos_press"
[compositions.nodes.input]
kind = "object"

[[compositions.nodes.input.fields]]
name = "keys"
[compositions.nodes.input.fields.value]
kind = "literal"
value = ["0", "enter", "y"]

[[compositions.nodes]]
id = "screen"
tool = "masc_dos_screen"
after = ["press"]
[compositions.nodes.input]
kind = "literal"
value = {}
```
