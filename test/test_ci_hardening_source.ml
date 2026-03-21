(** CI/dashboard hardening source guards. *)

open Alcotest

let rec find_source_root dir =
  let dune_project = Filename.concat dir "dune-project" in
  let git_dir = Filename.concat dir ".git" in
  if Sys.file_exists dune_project || Sys.file_exists git_dir then
    dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then
      Sys.getcwd ()
    else
      find_source_root parent

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> find_source_root (Sys.getcwd ())

let file_contains_pattern file_rel pattern =
  let source_root = source_root () in
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
       "maybe_evict_expired config");
  (* guardian GC cache eviction check removed — Guardian deleted (#1834) *)
  ignore (fun () -> ())

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
  check bool "war room surface imports hero strip" true
    (file_contains_pattern "dashboard/src/components/command/war-room.ts"
       "import { WarRoomHeroStrip } from './war-room-hero'");
  check bool "war room surface imports body grid" true
    (file_contains_pattern "dashboard/src/components/command/war-room.ts"
       "import { WarRoomBodyGrid } from './war-room-body'");
  check bool "war room hero exported from split file" true
    (file_contains_pattern "dashboard/src/components/command/war-room-hero.ts"
       "export function WarRoomHeroStrip");
  check bool "war room body exported from split file" true
    (file_contains_pattern "dashboard/src/components/command/war-room-body.ts"
       "export function WarRoomBodyGrid");
  check bool "backend normalizes postgres pooler url before connect" true
    (file_contains_pattern "lib/backend.ml"
       "pooler.supabase.com");
  check bool "backend_eio normalizes postgres pooler url before connect" true
    (file_contains_pattern "lib/backend_eio.ml"
       "pooler.supabase.com");
  check bool "council archive normalizes postgres url" true
    (file_contains_pattern "lib/council/archive.ml"
       "pooler.supabase.com");
  check bool "jiphyeon archive normalizes postgres url" true
    (file_contains_pattern "lib/jiphyeon/archive.ml"
       "pooler.supabase.com")

let () =
  run "ci_hardening_source"
    [
      ("source_guard", [
           test_case "sync and asset contracts" `Quick test_ci_sync_and_asset_contracts;
           test_case "health and ci diagnostics" `Quick test_health_and_ci_runner_diagnostics;
           test_case "route auth contracts" `Quick test_route_auth_contracts;
           test_case "input validation contracts" `Quick test_input_validation_contracts;
           test_case "dashboard component split contracts" `Quick test_dashboard_component_split_contracts;
         ]);
    ]
