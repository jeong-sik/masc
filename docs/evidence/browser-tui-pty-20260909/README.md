# Compiled TUI PTY verification

The Linux ARM64 candidate from CI run 34325400602, commit
`8765238ac898a338ffb41556e4c8267e85406ac2`, passed the repository's unmodified
`test/test_tui_keyboard_input.py <candidate>/masc_tui.exe browser-screenshot`
scenario inside `masc-imp-acceptance-linux:035`. Manifest SHA-256 values were
verified before execution. The container exited 0.

The scenario exercises screenshot rendering protocol output, pointer click and
drag geometry, viewport scrolling and resize, live client selection, scene
navigation and region focus/refresh using a real TUI process and PTY with a
synthetic HTTP backend. It does not prove a real Slack session or physical
terminal image rendering. Server-to-Firefox evidence is recorded separately in
`../browser-server-endpoints-20260909/`.

This candidate includes the physical fullscreen size and `v` key fixes from
`1f97c751a0`. Its manifest explicitly says `release_validated=false`; passing this
probe is not a release or deployment claim.
