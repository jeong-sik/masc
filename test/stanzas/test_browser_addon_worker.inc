(test
 (name test_browser_addon_observation)
 (modules test_browser_addon_observation)
 (libraries masc masc.browser_lane alcotest eio_main yojson))

(test
 (name test_browser_addon_tool)
 (modules test_browser_addon_tool)
 (libraries masc masc.browser_lane masc.time_compat masc.lane_addon_call_context
  masc.lane_addon_tool_result masc.tool_types mcp_protocol alcotest eio eio_main yojson))

(test
 (name test_browser_addon_owner)
 (modules test_browser_addon_owner)
 (libraries masc masc.browser_lane masc.time_compat alcotest eio eio_main))

(test
 (name test_browser_addon_owner_cleanup)
 (modules test_browser_addon_owner_cleanup)
 (libraries masc masc.browser_lane masc.time_compat masc.fs_compat alcotest eio eio_main eio.unix unix))

(test
 (name test_browser_addon_wire)
 (modules test_browser_addon_wire)
 (libraries masc masc.browser_lane alcotest))

(test
 (name test_browser_addon_service)
 (modules test_browser_addon_service)
 (libraries masc masc.browser_lane masc.time_compat alcotest eio eio.unix eio_main yojson unix))

(test
 (name test_browser_addon_socket)
 (modules test_browser_addon_socket)
 (libraries masc masc.native_addon_lease masc.fs_compat alcotest masc.agent_core.digest yojson uuidm unix)
 (deps (source_tree %{workspace_root}/config/prompts)))

(test
 (name test_browser_addon_client)
 (modules test_browser_addon_client)
 (libraries masc masc.browser_lane masc.masc_eio_context alcotest eio eio_main yojson unix))

(test
 (name test_browser_addon_uploads)
 (modules test_browser_addon_uploads)
 (libraries masc masc.browser_lane masc.fs_compat alcotest eio_main unix))

(test
 (name test_browser_addon_live_ego)
 (modules test_browser_addon_live_ego)
 (libraries masc masc.browser_lane masc.browser_configuration masc.time_compat
  masc.fs_compat masc.string_util masc_process alcotest base64 otoml eio eio_main yojson unix))

(test
 (name test_browser_addon_reply_policy)
 (modules test_browser_addon_reply_policy)
 (libraries masc masc.browser_lane masc.time_compat masc.lane_addon_call_context
  masc.lane_addon_tool_result masc.tool_types mcp_protocol alcotest eio eio.mock))

(test
 (name test_browser_addon_scoped_elements)
 (modules test_browser_addon_scoped_elements)
 (libraries masc masc.browser_lane masc.time_compat masc.lane_addon_call_context alcotest eio eio.mock yojson))
