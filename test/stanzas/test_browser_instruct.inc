(test
 (name test_browser_instruct)
 (modules test_browser_instruct)
 (libraries browser_addon_fixture masc masc.browser_lane masc.time_compat masc.tool_types
  masc.lane_addon_call_context alcotest yojson eio eio_main unix)
 (deps ../bin/masc_native_addon_launcher.exe))
