(test
 (name test_browser_task_capabilities)
 (modules test_browser_task_capabilities)
 (libraries masc masc.browser_lane masc.string_util masc.time_compat masc.tool_types
  masc.lane_addon_call_context masc.tool_schemas masc.masc_types alcotest yojson uuidm eio eio_main))
