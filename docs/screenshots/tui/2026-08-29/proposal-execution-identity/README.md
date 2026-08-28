# TUI proposal execution identity

This frame comes from the actual `masc_tui.exe` built at merged source head
`445dab4db08b84be24b3f7d6e58ac3b8d85d8a70`, served through ttyd and captured
from Chromium's `.xterm-screen` at 100 columns by 30 rows.

The fixture-backed interaction selected Keepers (`2`) and opened the selected
Keeper's durable calls (`t`). The frame shows the exact Assembler run,
`retained_match`, and the complete 64-character proposal id on two lines.

[Open the PNG](01-calls.png)

`[disconnected]` is expected in this isolated fixture because no live event
stream is supplied. The tool-call endpoint itself returned `health: ok`. No
screenshot text was replaced or edited after capture.
