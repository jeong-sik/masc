(** CI/dashboard hardening source guards. *)

open Alcotest

let file_contains_pattern file_rel pattern =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root file_rel in
  if not (Sys.file_exists path) then false
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let content = In_channel.input_all ic in
        let rec loop idx =
          let remaining = String.length content - idx in
          let plen = String.length pattern in
          remaining >= plen
          && (String.sub content idx plen = pattern || loop (idx + 1))
        in
        if String.length pattern = 0 then true else loop 0)

let test_ci_sync_and_asset_contracts () =
  check bool "pr sync script added" true
    (file_contains_pattern "scripts/check-pr-sync.sh" "workflow payload head");
  check bool "pr sync script falls back to pull ref" true
    (file_contains_pattern "scripts/check-pr-sync.sh" "refs/pull/${pr_number}/head");
  check bool "ci workflow verifies pr sync" true
    (file_contains_pattern ".github/workflows/ci.yml" "Verify PR sync");
  check bool "ci workflow passes pr number to sync check" true
    (file_contains_pattern ".github/workflows/ci.yml" "--pr-number \"$PR_NUMBER\"");
  check bool "pr hygiene no longer checks dashboard assets (gitignored)" true
    (not (file_contains_pattern "scripts/check-pr-hygiene.sh" "dashboard source or Vite config changed but assets/dashboard was not updated"))

let test_health_and_ci_runner_diagnostics () =
  check bool "health snapshot records baseline source" true
    (file_contains_pattern "scripts/health_snapshot.sh" "\"baseline\": {");
  check bool "health snapshot records regressions array" true
    (file_contains_pattern "scripts/health_snapshot.sh" "\"regressions\": ${regressions_json}");
  check bool "ci runner captures log file" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "TEST_LOG_FILE=");
  check bool "ci runner prints failure markers" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "failure markers (latest 20)");
  check bool "ci runner retries dune rpc lock failures in isolated build dir" true
    (file_contains_pattern "scripts/ci-run-tests.sh"
       "detected dune RPC/lock failure; retrying once with isolated build dir");
  check bool "ci runner tracks active build dir for diagnostics" true
    (file_contains_pattern "scripts/ci-run-tests.sh" "ACTIVE_TEST_BUILD_DIR")

let test_contract_harness_and_team_session_authz_contracts () =
  check bool "contract harness exposes extract_text helper" true
    (file_contains_pattern "scripts/harness/lib/test_framework.sh"
       "extract_text()");
  check bool "golden path harness uses extract_text helper" true
    (file_contains_pattern "scripts/harness/contract/golden_path_1_contract.sh"
       "| extract_text)");
  check bool "team session stop unauthorized path covered" true
    (file_contains_pattern "test/test_tool_team_session_misc.ml"
       "unauthorized stop denied");
  check bool "team session stop owner path covered" true
    (file_contains_pattern "test/test_tool_team_session_misc.ml"
       "owner stop allowed")

let test_route_auth_contracts () =
  check bool "http command-plane units use tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_command_plane_write.ml"
       {|with_tool_auth ~tool_name:"masc_unit_define"|});
  check bool "http command-plane dispatch tick use tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_command_plane_write.ml"
       {|with_tool_auth ~tool_name:"masc_dispatch_tick"|});
  check bool "http command-plane policy approve use tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_command_plane_write.ml"
       {|with_tool_auth ~tool_name:"masc_policy_approve"|});
  check bool "http keeper chat stream uses keeper tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_tool_auth ~tool_name:"masc_keeper_msg"|});
  check bool "h2 gateway units use tool auth" true
    (file_contains_pattern "lib/server/server_h2_gateway_routes_cp.ml"
       {|h2_authorize_tool state ~tool_name:"masc_unit_define"|});
  check bool "h2 gateway dispatch tick uses tool auth" true
    (file_contains_pattern "lib/server/server_h2_gateway_routes_cp.ml"
       {|h2_authorize_tool state ~tool_name:"masc_dispatch_tick"|});
  check bool "h2 gateway operator confirm uses tool auth" true
    (file_contains_pattern "lib/server/server_h2_gateway_routes_cp.ml"
       {|h2_authorize_tool state ~tool_name:"masc_operator_confirm"|})

let test_http_write_auth_contracts () =
  check bool "server auth no longer accepts query token fallback" true
    (not
       (file_contains_pattern "lib/server/server_auth.ml"
          {|query_param request "token"|}));
  check bool "server auth defines token-bound permission helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let authorize_token_bound_permission_request");
  check bool "server auth exposes token-bound route helper" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "and with_token_permission_auth");
  check bool "server auth defines same-origin browser guard" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "let ensure_same_origin_browser_request");
  check bool "tool auth enforces same-origin when no bearer token" true
    (file_contains_pattern "lib/server/server_auth.ml"
       "else ensure_same_origin_browser_request request");
  check bool "broadcast route requires token-bound broadcast permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_token_permission_auth ~permission:Types.CanBroadcast|});
  check bool "keeper config update requires admin permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_dashboard.ml"
       {|with_token_permission_auth ~permission:Types.CanAdmin|});
  check bool "board vote route requires board vote tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|with_tool_auth ~tool_name:"masc_board_vote"|});
  check bool "board vote route overwrites voter from auth identity" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|json_upsert_string_field "voter" agent_name|});
  check bool "board comment route overwrites author from auth identity" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|json_upsert_string_field "author" agent_name|});
  check bool "provider runs post requires admin permission" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       {|with_token_permission_auth ~permission:Types.CanAdmin|})

let test_http_read_surface_contracts () =
  check bool "room status route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/status" (fun request reqd ->
       with_read_auth|});
  check bool "room tasks route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/tasks" (fun request reqd ->
       with_read_auth|});
  check bool "room agents route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/agents" (fun request reqd ->
       with_read_auth|});
  check bool "room messages route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_room.ml"
       {|"/api/v1/messages" (fun request reqd ->
       with_read_auth|});
  check bool "provider run status route now requires read auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_provider_runs.ml"
       {|"/api/v1/agent-runs/" (fun request reqd ->
       with_read_auth|})

let test_input_validation_contracts () =
  (* Bug #1602: broadcast must reject empty messages *)
  check bool "broadcast validates empty message" true
    (file_contains_pattern "lib/tool_inline_dispatch_comm.ml"
       {|"Broadcast message cannot be empty"|});
  check bool "broadcast trims whitespace before check" true
    (file_contains_pattern "lib/tool_inline_dispatch_comm.ml"
       {|String.trim message|});
  (* Bug #1609: cache must have automatic eviction *)
  check bool "cache has maybe_evict_expired function" true
    (file_contains_pattern "lib/cache_eio.ml"
       "let maybe_evict_expired config");
  check bool "cache get triggers batch eviction" true
    (file_contains_pattern "lib/cache_eio.ml"
       "maybe_evict_expired config")

let test_dashboard_component_split_contracts () =
  check bool "proof view imports proof helpers" true
    (file_contains_pattern "dashboard/src/components/proof.ts"
       {|from './proof-helpers'|});
  check bool "proof view imports proof sections" true
    (file_contains_pattern "dashboard/src/components/proof.ts"
       {|from './proof-sections'|});
  check bool "proof helpers export verdict reasons" true
    (file_contains_pattern "dashboard/src/components/proof-helpers.ts"
       "export function verdictReasonLines");
  check bool "proof helpers export timeline dedupe" true
    (file_contains_pattern "dashboard/src/components/proof-helpers.ts"
       "export function dedupeTimeline");
  check bool "proof sections export selection card" true
    (file_contains_pattern "dashboard/src/components/proof-sections.ts"
       "export function SelectionCard");
  check bool "proof sections export actor contribution row" true
    (file_contains_pattern "dashboard/src/components/proof-sections.ts"
       "export function ActorContributionRow");
  check bool "mission cards re-export briefing card" true
    (file_contains_pattern "dashboard/src/components/mission-cards.ts"
       "export { MissionBriefingCard } from './mission-briefing-card'");
  check bool "mission cards re-export attention card" true
    (file_contains_pattern "dashboard/src/components/mission-cards.ts"
       "export { AttentionCard } from './mission-attention-card'");
  check bool "mission briefing card exported from split file" true
    (file_contains_pattern "dashboard/src/components/mission-briefing-card.ts"
       "export function MissionBriefingCard");
  check bool "mission attention card exported from split file" true
    (file_contains_pattern "dashboard/src/components/mission-attention-card.ts"
       "export function AttentionCard");
  check bool "swarm surface re-exports overview panel" true
    (file_contains_pattern "dashboard/src/components/command/swarm.ts"
       "export { SwarmOverviewPanel } from './swarm-overview-panel'");
  check bool "swarm surface re-exports live panels" true
    (file_contains_pattern "dashboard/src/components/command/swarm.ts"
       "export { SwarmLivePanels } from './swarm-live-panels'");
  check bool "swarm overview panel exported from split file" true
    (file_contains_pattern "dashboard/src/components/command/swarm-overview-panel.ts"
       "export function SwarmOverviewPanel");
  check bool "swarm live panels exported from split file" true
    (file_contains_pattern "dashboard/src/components/command/swarm-live-panels.ts"
       "export function SwarmLivePanels");
  check bool "room backend setup normalizes postgres pooler url before connect" true
    (file_contains_pattern "lib/room/room_utils_backend_setup.ml"
       "pooler.supabase.com")

let test_activity_surface_contracts () =
  check bool "activity tab exposes activity graph label" true
    (file_contains_pattern "dashboard/src/components/activity.ts"
       "활동 그래프");
  check bool "dashboard fetches canonical activity graph route" true
    (file_contains_pattern "dashboard/src/api/actions.ts"
       "/api/v1/activity/graph");
  check bool "server exposes canonical activity events route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|"/api/v1/activity/events"|});
  check bool "server exposes canonical activity graph route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
       {|"/api/v1/activity/graph"|});
  check bool "server drops legacy social graph alias" true
    (not
       (file_contains_pattern "lib/server/server_routes_http_routes_activity.ml"
          {|"/api/v1/social-graph"|}));
  check bool "dashboard semantics use activity graph surface id" true
    (file_contains_pattern "lib/dashboard/dashboard_semantics.ml"
       {|surface ~id:"activity_graph"|});
  check bool "room top-level module emits activity events" true
    (file_contains_pattern "lib/room.ml"
       "Activity_graph.emit config");
  check bool "room task lifecycle emits activity events via hook" true
    (file_contains_pattern "lib/room/room_task.ml"
       "!Room_hooks.activity_emit_fn config");
  check bool "room broadcast emits activity events via hook" true
    (file_contains_pattern "lib/room/room_state.ml"
       "!Room_hooks.activity_emit_fn config");
  check bool "board success paths emit activity events" true
    (file_contains_pattern "lib/tool_inline_dispatch_extra.ml"
       "Activity_graph.emit config");
  check bool "team session store emits activity events" true
    (file_contains_pattern "lib/team_session/team_session_store.ml"
       "Activity_graph.emit config")

let test_local_review_script_contracts () =
  check bool "local review script exists" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "#!/usr/bin/env bash");
  check bool "local review script caches under .masc review-cache" true
    (file_contains_pattern "scripts/review/local-review.sh"
       ".masc/review-cache/local-review");
  check bool "local review script resolves shared git common dir cache root" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--git-common-dir");
  check bool "local review script keeps pending registry" true
    (file_contains_pattern "scripts/review/local-review.sh"
       ".pending.json");
  check bool "local review script chunks large diffs" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "MASC_LOCAL_REVIEW_CHUNK_BYTES");
  check bool "local review script bounds reviewer request time" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--max-time");
  check bool "local review script exposes cache key print" true
    (file_contains_pattern "scripts/review/local-review.sh"
       "--print-cache-key")

let test_keeper_oas_cleanup_contracts () =
  check bool "keeper config no longer exposes stale unified turn flag" true
    (not
       (file_contains_pattern "lib/keeper/keeper_config.ml"
          "MASC_KEEPER_UNIFIED_TURN"));
  check bool "keeper turn comment no longer mentions context manager" true
    (not
       (file_contains_pattern "lib/keeper/keeper_turn.ml"
          "Context_manager"));
  check bool "tool compact comment now references OAS-backed pipeline" true
    (file_contains_pattern "lib/tool_compact.ml"
       "OAS-backed compaction pipeline")

let test_dashboard_executor_pool_contracts () =
  check bool "dashboard core defines executor pool helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "let run_dashboard_compute");
  check bool "dashboard core submits compute to executor pool" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "Eio.Executor_pool.submit_exn");
  check bool "mission refresh loop uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "run_dashboard_compute ~mode:Inline_shared ~sw ~clock ~config:room_config");
  check bool "mission actor path uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http_core.ml"
       "run_dashboard_compute ~mode ~sw ~clock");
  check bool "execution refresh loop uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock ~config:room_config");
  check bool "execution parameterized path uses dashboard compute helper" true
    (file_contains_pattern "lib/server/server_dashboard_http.ml"
       "run_dashboard_compute ~mode:Offloaded_readonly ~sw ~clock");
  check bool "server bootstrap wires executor pool into dashboard" true
    (file_contains_pattern "lib/server/server_runtime_bootstrap.ml"
       "Server_dashboard_http.set_executor_pool exec_pool")

let test_transport_route_contracts () =
  check bool "frontend exposes ws discovery route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.get "/ws" websocket_discovery_handler|});
  check bool "frontend exposes webrtc offer route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.post "/webrtc/offer"|});
  check bool "frontend exposes webrtc answer route" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       {|Http.Router.post "/webrtc/answer"|});
  check bool "frontend webrtc routes require tool auth" true
    (file_contains_pattern "lib/server/server_routes_http_routes_frontend.ml"
       "let webrtc_signaling_handler ~tool_name signaling_fn request reqd =\n  with_tool_auth ~tool_name");
  check bool "h2 gateway exposes webrtc offer route" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|`POST, "/webrtc/offer"|});
  check bool "h2 gateway exposes webrtc answer route" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|`POST, "/webrtc/answer"|});
  check bool "h2 gateway webrtc routes enforce tool auth" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|authorize_tool_request
                ~base_path:state.Mcp_server.room_config.base_path
                ~tool_name:"masc_webrtc_offer"|});
  check bool "h2 gateway respects webrtc disabled state" true
    (file_contains_pattern "lib/server/server_h2_gateway.ml"
       {|Server_webrtc_transport.is_enabled ()|})

let test_mermaid_xss_contracts () =
  check bool "mermaid securityLevel is strict (not loose)" true
    (file_contains_pattern "dashboard/src/components/command/helpers.ts"
       "securityLevel: 'strict'");
  check bool "mermaid securityLevel loose is absent" true
    (not
       (file_contains_pattern "dashboard/src/components/command/helpers.ts"
          "securityLevel: 'loose'"))

let () =
  run "ci_hardening_source"
    [
      ("source_guard", [
           test_case "sync and asset contracts" `Quick test_ci_sync_and_asset_contracts;
           test_case "contract harness and team session authz contracts" `Quick
             test_contract_harness_and_team_session_authz_contracts;
           test_case "health and ci diagnostics" `Quick test_health_and_ci_runner_diagnostics;
           test_case "route auth contracts" `Quick test_route_auth_contracts;
           test_case "http write auth contracts" `Quick test_http_write_auth_contracts;
           test_case "http read surface contracts" `Quick test_http_read_surface_contracts;
           test_case "input validation contracts" `Quick test_input_validation_contracts;
           test_case "dashboard component split contracts" `Quick test_dashboard_component_split_contracts;
           test_case "activity surface contracts" `Quick test_activity_surface_contracts;
           test_case "local review script contracts" `Quick test_local_review_script_contracts;
           test_case "keeper oas cleanup contracts" `Quick test_keeper_oas_cleanup_contracts;
           test_case "dashboard executor pool contracts" `Quick
             test_dashboard_executor_pool_contracts;
           test_case "transport route contracts" `Quick
             test_transport_route_contracts;
           test_case "mermaid xss contracts" `Quick test_mermaid_xss_contracts;
         ]);
    ]
