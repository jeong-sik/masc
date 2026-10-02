# Usage views

The operator screenshot mixed quota windows, per-scope history and Keeper metrics into one scroll list. Long catalogue explanations widened every quota row and pushed reset times away from the measurements.

Usage now has three views. `v` cycles Plan, Trend and Keepers. `w` opens Trend and cycles its 1/7/14 UTC day range. `p` enters or leaves Telemetry; the chosen Usage view survives that round trip. Each view resets scroll when selected.

Plan groups windows and identity metadata into account cards. At 130 cells of available width cards pair; narrower terminals stack them. Cards preserve scope IDs, provider labels, reported utilization, reset times and observation ages. Catalogue exhaustion has its own wrapped line and remains independent of provider window utilization and reset. A full limit classified as counting other use stays dim. Failed reads remain unavailable rather than becoming zero.

Trend gives each scope a heading, window label and readable sparkline. Keepers gives each Keeper its own tokens, cost and coverage rows. The navigation remains fixed during scrolling; short screens reduce navigation spacing to preserve content.

References: [Lip Gloss](https://github.com/charmbracelet/lipgloss) for bordered composition, [btop](https://github.com/aristocratos/btop) for aligned meters, and [Textual layouts](https://textual.textualize.io/guide/layout/) for responsive composition. These inform presentation, not quota semantics.

Verification uses `test_tui_overview_providers`, `test_tui_keys`, `test_tui_keyboard_input-dashboard-usage` and `test_tui_usage_studio_pty`. The focused PTY suite emits original ANSI frames, dimensions, binary hash and rendered text. Targeted Test CI replays those frames through ttyd/xterm in Chromium and checks observed terminal rows before saving screenshots. Artifacts are CI fixture evidence; they do not prove the installed or production screen.
