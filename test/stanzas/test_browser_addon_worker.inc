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
 (libraries masc masc.browser_lane masc.time_compat masc.fs_compat alcotest eio eio_main eio.unix unix))

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

(test
 (name test_browser_addon_uploads)
 (modules test_browser_addon_uploads)
 (libraries masc masc.browser_lane masc.fs_compat masc.time_compat
  masc.lane_addon_call_context mcp_protocol alcotest eio eio.unix eio_main yojson unix))

(test
 (name test_browser_addon_live_bidi)
 (modules test_browser_addon_live_bidi)
 (libraries masc masc.browser_lane masc.browser_configuration masc.time_compat
  masc.fs_compat masc_process alcotest eio eio_main yojson unix)
 (deps ../bin/masc_native_addon_launcher.exe ../bin/masc_browser_process_owner.exe)
 (action (run %{test} %{dep:../bin/masc_native_addon_launcher.exe}
   %{dep:../bin/masc_browser_process_owner.exe})))

; Real Firefox via the installed browser Addon, not a standalone host.
; scripts/probe-browser-addon-firefox.py supplies isolated loopback pages.
(executable
 (name browser_addon_firefox_probe)
 (modules browser_addon_firefox_probe)
 (libraries masc masc.server masc.browser_lane masc.browser_configuration masc.time_compat
  masc.fs_compat masc.config masc.runtime masc.masc_eio_context masc.native_addon_lease
  masc.skill_snapshot masc.skill_snapshot_service masc.skill_reference
  masc.lane_addon_call_context masc.tool_types exact_output_fixture
  eio eio_main eio.unix yojson base64 unix mirage-crypto-rng.unix mtime.clock.os))

; Real session-owned Gecko upload/download and host artifact retention.
(executable
 (name browser_addon_gecko_transfer_probe)
 (modules browser_addon_gecko_transfer_probe)
 (libraries masc masc.server masc.browser_lane masc.browser_configuration masc.time_compat
  masc.fs_compat masc.config masc.runtime masc.masc_eio_context masc.multimodal masc.masc_tool_blob_store
  masc.skill_snapshot masc.skill_snapshot_service masc.skill_reference
  masc.lane_addon_call_context masc.tool_types masc.agent_core exact_output_fixture cohttp
  eio eio_main eio.unix yojson unix mirage-crypto-rng.unix))

; Actual external extension/native messaging/production HTTP ingress and queues.
(executable
 (name browser_addon_webextension_probe)
 (modules browser_addon_webextension_probe)
 (libraries masc masc.server masc.browser_lane masc.browser_configuration masc.time_compat
  masc.fs_compat masc.config masc.runtime masc.masc_eio_context masc.workspace_connection
  masc.multimodal masc.skill_snapshot masc.skill_snapshot_service
  masc.lane_addon_call_context masc.tool_types exact_output_fixture
  httpun-eio httpun gluten eio eio_main eio.unix yojson unix mirage-crypto-rng.unix))
