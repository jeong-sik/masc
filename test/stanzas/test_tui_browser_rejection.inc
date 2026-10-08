(test
 (name test_tui_browser_rejection)
 (modules test_tui_browser_rejection)
 (libraries masc masc.tool_types masc.browser_lane masc.time_compat masc.string_util
  masc_tui_browser_rejection masc_tui_types alcotest eio_main eio yojson))
