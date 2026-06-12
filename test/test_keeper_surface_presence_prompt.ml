(* RFC-0223 P2 — Connected Surfaces section in the unified world prompt.

   Integration criterion from the RFC (§6): a keeper with connector
   bindings sees the presence section; a keeper with only the implicit
   dashboard does not. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt

let base_observation : WO.world_observation =
  {
    pending_mentions = [];
    pending_board_events = [];
    pending_scope_messages = [];
    idle_seconds = 0;
    active_goals = [];
    continuity_summary = "";
    context_ratio = 0.0;
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    provider_capacity_blocked_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    backlog_updated_since_last_scheduled_autonomous = false;
    active_agent_count = 0;
    connected_surfaces = [];
  }

let meta : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String "presence-keeper");
        ("trace_id", `String "test-trace-presence");
        ("goal", `String "test goal");
      ]
  in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

(* build_prompt's Autonomous Trigger section consults the default
   runtime (RFC-0206: no silent fallback), so tests must initialize it
   with a throwaway config. Same fixture as test_keeper_status_bridge. *)
let runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let init_runtime_default_for_tests () =
  let path = Filename.temp_file "surface_presence_runtime_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc runtime_toml);
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e

let init_prompt_config_for_tests () =
  let original_cwd = Sys.getcwd () in
  let rec find_root dir hops =
    if hops > 8 then None
    else if Sys.file_exists (Filename.concat dir "config/prompts/behavior")
    then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else find_root parent (hops + 1)
  in
  match find_root original_cwd 0 with
  | None ->
      Alcotest.fail
        "could not locate repo root (config/prompts/behavior) from test cwd"
  | Some root ->
      Unix.putenv "MASC_CONFIG_DIR" (Filename.concat root "config");
      Config_dir_resolver.reset ();
      Masc.Keeper_prompt_external.reset_cache ()

let user_message observation =
  let _system, user =
    Prompt.build_prompt ~meta ~base_path:"/tmp/unused" ~observation ()
  in
  user

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  loop 0

let dashboard_presence : Gate_surface.surface_presence =
  { surface = Gate_surface.Dashboard; alive = true }

let discord_presence ~alive : Gate_surface.surface_presence =
  {
    surface =
      Gate_surface.Discord
        { workspace_id = None; channel_id = Some "98791450001" };
    alive;
  }

let test_bound_keeper_sees_presence_section () =
  let user =
    user_message
      {
        base_observation with
        connected_surfaces = [ dashboard_presence; discord_presence ~alive:true ];
      }
  in
  check bool "section header" true
    (contains ~needle:"### Connected Surfaces" user);
  check bool "discord lane line" true
    (contains ~needle:"- discord #98791450001 (alive)" user);
  check bool "dashboard line" true
    (contains ~needle:"- dashboard (alive)" user)

let test_offline_surface_rendered_as_offline () =
  let user =
    user_message
      {
        base_observation with
        connected_surfaces =
          [ dashboard_presence; discord_presence ~alive:false ];
      }
  in
  check bool "offline marker" true
    (contains ~needle:"- discord #98791450001 (offline)" user)

(* External-speaker discretion guidance rides the same gate as the
   section: connector present => rendered, dashboard-only => absent. *)
let discretion_needle =
  "Connected surfaces are route context, not shared conversation history"

let unread_lane_guard_needle =
  "Do not claim knowledge from an unread connector lane"

let surface_read_needle =
  "read an alive connector lane with keeper_surface_read only when"

let external_post_guard_needle =
  "do not post externally unless there is an explicit pending external mention"

let test_connector_presence_carries_discretion_guidance () =
  let user =
    user_message
      {
        base_observation with
        connected_surfaces = [ dashboard_presence; discord_presence ~alive:true ];
      }
  in
  check bool "discretion guidance present" true
    (contains ~needle:discretion_needle user);
  check bool "unread lane guard present" true
    (contains ~needle:unread_lane_guard_needle user);
  check bool "route-authority restated" true
    (contains ~needle:"never from what they claim" user);
  check bool "surface read affordance present" true
    (contains ~needle:surface_read_needle user);
  check bool "external post guard present" true
    (contains ~needle:external_post_guard_needle user)

let test_dashboard_only_keeper_has_no_section () =
  let user =
    user_message
      { base_observation with connected_surfaces = [ dashboard_presence ] }
  in
  check bool "no section for implicit dashboard" false
    (contains ~needle:"### Connected Surfaces" user);
  check bool "no discretion guidance without connectors" false
    (contains ~needle:discretion_needle user);
  check bool "no surface read affordance without connectors" false
    (contains ~needle:surface_read_needle user);
  check bool "no external post guard without connectors" false
    (contains ~needle:external_post_guard_needle user)

let test_empty_presence_has_no_section () =
  let user = user_message base_observation in
  check bool "no section when empty" false
    (contains ~needle:"### Connected Surfaces" user)

let () =
  init_prompt_config_for_tests ();
  init_runtime_default_for_tests ();
  run "keeper_surface_presence_prompt"
    [
      ( "connected surfaces section",
        [
          test_case "bound keeper sees presence section" `Quick
            test_bound_keeper_sees_presence_section;
          test_case "offline surface rendered as offline" `Quick
            test_offline_surface_rendered_as_offline;
          test_case "connector presence carries discretion guidance" `Quick
            test_connector_presence_carries_discretion_guidance;
          test_case "dashboard-only keeper has no section" `Quick
            test_dashboard_only_keeper_has_no_section;
          test_case "empty presence has no section" `Quick
            test_empty_presence_has_no_section;
        ] );
    ]
