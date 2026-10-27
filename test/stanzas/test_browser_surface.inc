(test
 (name test_browser_surface)
 (modules test_browser_surface)
 (libraries masc masc.browser_lane masc.time_compat masc.tool_types masc.lane_addon_call_context
  masc.tool_schemas masc.masc_types
  alcotest eio_main eio yojson base64))
