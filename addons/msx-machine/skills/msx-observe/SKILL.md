---
name: msx-observe
description: Read the current MSX screen from the attached machine's PNG and preserve its frame identity when identifying prompts, dates, menus or visible changes.
---

Call the attached Add-on's `masc_msx_screen` once to observe without sending
input or advancing time. Read the PNG image in that tool result together with
its structured observation and frame number. Focus on the requested visible
text or pixels; mark unreadable characters rather than guessing. Bitmap
`screen_text` is name-table data, not OCR of the image.

Describe the captured frame, not an assumed current state: another player may
advance the shared machine while you interpret it. Preserve the frame number
and the tool result as evidence. After further input, capture again before
confirming the state. Watching does not establish driving ownership.

If the current model cannot read the returned image, report that limitation
and retain the observation; do not invent an artifact handle or infer the
screen from game knowledge. If the tool is unavailable or the Add-on was
detached, report that no fresh observation was obtained.
