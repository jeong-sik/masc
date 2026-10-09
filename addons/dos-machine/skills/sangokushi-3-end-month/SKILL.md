---
name: sangokushi-3-end-month
description: "Attempt the observed end-month sequence in 삼국지 III (0, enter, y) and inspect the resulting PNG. Use only at a <군주>님 …에 명령을(0-9)? prompt of your own ruler; settling does not guarantee completion."
---

# 삼국지 III: end the month

Presses `0`, `enter`, `y` — 휴양 as the last command, then yes to
이달의 명령을 끝내겠습니까(Y/N)? — and returns the resulting screen. Its default
batch advances between keys on an empty-poll/unchanged-screen observation,
which can occur during a transition. Check `keys_pressed` for the delivered
prefix and inspect the PNG before sending any remaining key. Neither `settled`
nor delivery of all three keys proves the AI rulers finished their turns.
If a transition is still visible, run `masc_dos_step` with `until_ready: false`
and inspect again. Use separate single-key explicit runs from `dos-play` when
the intermediate prompts need inspection.

Use it only when the prompt names your own ruler. The game knowledge is in
the `sangokushi-3` Skill; passing the controller to the next player is in
`dos-play`.

```toml composition
[[compositions]]
name = "sangokushi-3-end-month"
description = "Send the observed end-month sequence (0, enter, y) and inspect the resulting screen."
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
