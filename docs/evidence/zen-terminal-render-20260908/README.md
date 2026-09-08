# Zen rendered pixels through the terminal — 2026-09-08

A real ordinary Zen 1.22b profile was connected through its native extension,
client `74b54fd3-5882-4aba-afb7-3c6ddaeb9f4e`. The operator opened the owned
loopback CSS fixture in tab 9. No account page was used for this measurement.

[Measurement](measurement.json) retains the exact server identity and five
captures. Three native `masc_browser_interact` calls moved the real page through
scrollY 120, 240 and 360; a fourth returned it to 0. Each successful scroll was
followed by a separate HTTP screenshot of the same client/tab/URL. Capture
round-trips were 102.94–112.06 ms, and the first three scroll calls took
6.43–17.40 ms. Five captures on one local page are not a terminal frame-rate or
video benchmark. The top and restored images need not be byte-identical; the
scroll result, not their hash equality, establishes restoration to scrollY 0.

[Actual TUI receipt](tui.json) records an independent installed TUI binary,
SHA-256 `3b451b608baab7162ec58312f64ee38cda9616683d89a967b0cf60c1d5a0087a`,
opening the live fixture through real production HTTP. A PTY answered the Kitty
capability query and decoded the PNG chunks the TUI emitted. Those bytes match
[top.png](top.png) exactly (397,248 bytes, SHA-256
`cd7e52720ff60e824a5f5566019bdf85643f7f47808cf2d00410ef95030953c2`).
The independent probe TUI exited normally. This proves image transport through
the real TUI path; it is not a physical Ghostty screenshot.

This measurement predates the interactive viewport implementation in
[PR #34283](https://github.com/jeong-sik/masc/pull/34283). The scroll actions here
were MCP calls, not keys injected into that changed TUI. The newly added TUI
scroll/refresh, late-frame, paste and resize scenarios still require an executable
containing that implementation. Source changes, protocol measurement and changed
binary execution must remain distinct.

[Open the visual comparison](index.html). The fixture exercises CSS Grid,
gradients, shadows, Korean fonts and a sticky header. [fixture.html](fixture.html)
can be opened directly; `python3 fixture.py` serves it on a loopback ephemeral
port recorded beside the script in `fixture.json`.
