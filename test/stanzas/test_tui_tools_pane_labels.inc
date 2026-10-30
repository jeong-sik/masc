(test
 (name test_tui_tools_pane_labels)
 (modules test_tui_tools_pane_labels)
 ; The two label call sites the 5th rejection names live in
 ; masc_tui_render_tools's tools_display_lines; this test executes that
 ; function with a decoded async observation and a decoded Skill-activation
 ; ledger, so the drawn rows are the function's own output.
 (libraries masc masc.masc_types masc.runtime masc_tui_types masc_tui_theme masc_tui_render_tools alcotest yojson masc.agent_core.digest))
