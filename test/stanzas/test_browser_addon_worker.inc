(test
 (name test_browser_addon_registration)
 (modules test_browser_addon_registration)
 (libraries masc masc.browser_lane masc.fs_compat alcotest yojson uuidm unix))

(test
 (name test_browser_addon_observation)
 (modules test_browser_addon_observation)
 (libraries masc alcotest yojson))

(test
 (name test_browser_addon_tool)
 (modules test_browser_addon_tool)
 (libraries masc masc.browser_lane masc.time_compat masc.lane_addon_call_context
  masc.lane_addon_tool_result masc.tool_types mcp_protocol alcotest eio eio_main yojson uuidm))

(test
 (name test_browser_addon_owner)
 (modules test_browser_addon_owner)
 (libraries masc masc.browser_lane masc.time_compat alcotest eio eio_main yojson uuidm))

(test
 (name test_browser_addon_owner_cleanup)
 (modules test_browser_addon_owner_cleanup)
 (libraries masc masc.browser_lane alcotest eio eio_main))

(executable
 (name test_browser_process_owner)
 (modules test_browser_process_owner)
 (libraries masc.browser_process_owner masc.native_addon_lease masc_process alcotest yojson unix))

(rule
 (alias runtest-browser-process-owner)
 (action (run %{exe:test_browser_process_owner.exe}
   %{exe:../bin/masc_native_addon_launcher.exe} %{exe:../bin/masc_browser_process_owner.exe})))

(alias
 (name runtest)
 (deps (alias runtest-browser-process-owner)))

(test
 (name test_browser_addon_wire)
 (modules test_browser_addon_wire)
 (libraries masc masc.browser_lane alcotest yojson))

(test
 (name test_browser_addon_service)
 (modules test_browser_addon_service)
 (libraries masc masc.time_compat alcotest eio eio_main yojson unix))

(test
 (name test_browser_addon_socket)
 (modules test_browser_addon_socket)
 (libraries masc masc.native_addon_lease masc.browser_configuration alcotest yojson uuidm unix))

(test
 (name test_browser_addon_client)
 (modules test_browser_addon_client)
 (libraries masc masc.browser_lane masc.masc_eio_context alcotest eio eio_main yojson unix))

(test
 (name test_browser_addon_automation)
 (modules test_browser_addon_automation)
 (libraries masc masc.browser_lane masc.browser_configuration masc.native_addon_lease
  masc.time_compat masc.fs_compat alcotest eio eio.unix eio_main yojson uuidm unix))
