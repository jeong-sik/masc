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
  check bool "ci workflow verifies pr sync" true
    (file_contains_pattern ".github/workflows/ci.yml" "Verify PR sync");
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
    (file_contains_pattern "scripts/ci-run-tests.sh" "failure markers (latest 20)")

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

let test_input_validation_contracts () =
  (* Bug #1602: broadcast must reject empty messages *)
  check bool "broadcast validates empty message" true
    (file_contains_pattern "lib/tool_inline_dispatch.ml"
       {|"Broadcast message cannot be empty"|});
  check bool "broadcast trims whitespace before check" true
    (file_contains_pattern "lib/tool_inline_dispatch.ml"
       {|String.trim message|});
  (* Bug #1609: cache must have automatic eviction *)
  check bool "cache has maybe_evict_expired function" true
    (file_contains_pattern "lib/cache_eio.ml"
       "let maybe_evict_expired config");
  check bool "cache get triggers batch eviction" true
    (file_contains_pattern "lib/cache_eio.ml"
       "maybe_evict_expired config");
  check bool "guardian GC runs cache eviction" true
    (file_contains_pattern "lib/guardian.ml"
       "Cache_eio.evict_expired config")

let () =
  run "ci_hardening_source"
    [
      ("source_guard", [
           test_case "sync and asset contracts" `Quick test_ci_sync_and_asset_contracts;
           test_case "health and ci diagnostics" `Quick test_health_and_ci_runner_diagnostics;
           test_case "route auth contracts" `Quick test_route_auth_contracts;
           test_case "input validation contracts" `Quick test_input_validation_contracts;
         ]);
    ]
