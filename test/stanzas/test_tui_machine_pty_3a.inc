; RFC §5 3a (#38815): the candidate spectator TUI over a real PTY against the
; in-process lane-addon router and DOS fixture worker. Skips without
; MASC_TUI_3A_BIN. An (executable), not a (test): no @runtest alias runs it,
; so a plain checkout never reports that skip as green. Run explicitly:
; MASC_TUI_3A_BIN=<candidate> dune exec test/test_tui_machine_pty_3a.exe
(executable
 (name test_tui_machine_pty_3a)
 (modules test_tui_machine_pty_3a)
 (libraries machine_worker_fixture masc.machine_configuration masc_test_deps yojson base64 bigstringaf unix eio eio_main masc.masc_core masc.machine_live_publication masc.msx_lane masc.dos_lane masc.machine_action_feed masc.server masc_tui_machine_live digestif masc.masc_types masc.auth httpun gluten))
