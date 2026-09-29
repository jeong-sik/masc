# #39827 compact portrait evidence

Base: `6fbf735a6c0793d5939d6d9d193e75d93bbe94e9` (before and after). The after binary has only the source changes in this draft on that base. SHA-256 values are in `*-binary.sha256`.

`capture.py` uses the real TUI binary and the existing PTY fixture to capture `/about` and Keeper alpha's Info pane at 80×32 and 140×32. Each `before/after-*-*.txt` is the terminal screen after a completed frame, with only terminal padding spaces trimmed from each row. The PNGs are separate pixel previews from `keeper_portrait_preview.exe` at the two mosaic image sizes; they are not claimed as terminal screenshots.

Local verification after the final flame-tip adjustment:

- `scripts/dune-local.sh build bin/masc_tui.exe` — exit 0.
- `test/test_tui_keeper_portrait.exe` — 8/8.
- `test/test_tui_emblem_screen.exe` — 10/10.
- `test/test_tui_keeper_portrait_pty.py` — 3 scenarios PASS.
- `test/test_tui_emblem_screen_pty.py` — 11 scenarios PASS.
- Captured screens: 32 rows each; every row fits its 80 or 140 cell width. After removing only the half-block picture cells and whitespace, Info text is identical. The /about text is identical except for the fixture's temporary base path and port. The preview renders a named candle with face, flame, shading and small horns; the narrow 24-pixel features remain small.

The 24/40 PNGs are direct pixel outputs. Kitty transport continues to use the original full-resolution image; the compact drawing is used only for the text terminal mosaic.
