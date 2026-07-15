(* RFC-0223 P2 — Connected Surfaces section in the unified world prompt.

   Integration criterion from the RFC (§6): a keeper with connector
   bindings sees the presence section; a keeper with only the implicit
   dashboard does not. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt
module KTP = Masc.Keeper_types_profile

let has_repo_prompts root =
  Sys.file_exists (Filename.concat root "config/prompts/keeper.unified.system.md")

let repo_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when has_repo_prompts root -> root
  | _ ->
    let rec ascend path =
      if has_repo_prompts path then path
      else
        let parent = Filename.dirname path in
        if String.equal parent path then Sys.getcwd () else ascend parent
    in
    ascend (Sys.getcwd ())

let restore_env name = function
  | Some value -> Unix.putenv name value
  | None -> Unix.putenv name ""

let with_repo_prompt_config f =
  let root = repo_root () in
  let config_dir = Filename.concat root "config" in
  let prompts_dir = Filename.concat config_dir "prompts" in
  let original_config = Sys.getenv_opt "MASC_CONFIG_DIR" in
  Fun.protect
    ~finally:(fun () ->
      restore_env "MASC_CONFIG_DIR" original_config;
      Config_dir_resolver.reset ();
      Prompt_registry.clear ())
    (fun () ->
      Unix.putenv "MASC_CONFIG_DIR" config_dir;
      Config_dir_resolver.reset ();
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir prompts_dir;
      Masc.Prompt_defaults.init ();
      Masc.Keeper_prompt_external.reset_cache ();
      f ())

let base_observation : WO.world_observation =
  {
    pending_messages = [];
    pending_board_events = [];
    keeper_invocation_joins = [];
    idle_seconds = 0;
    active_goals = [];
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    failed_task_count = 0;
    pending_verification_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_updated_since_last_scheduled_autonomous = false;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
  }

let meta : Masc.Keeper_meta_contract.keeper_meta =
  let json =
    `Assoc
      [
        ("name", `String "presence-keeper");
        ("trace_id", `String "test-trace-presence");
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

let system_prompt ?profile_defaults observation =
  let system, _user =
    Prompt.build_prompt ~meta ~base_path:"/tmp/unused" ?profile_defaults
      ~observation ()
  in
  system

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

let test_dashboard_only_keeper_has_no_section () =
  let user =
    user_message
      { base_observation with connected_surfaces = [ dashboard_presence ] }
  in
  check bool "no section for implicit dashboard" false
    (contains ~needle:"### Connected Surfaces" user)

let test_empty_presence_has_no_section () =
  let user = user_message base_observation in
  check bool "no section when empty" false
    (contains ~needle:"### Connected Surfaces" user)

let test_namespace_state_names_running_keeper_fibers () =
  let user =
    user_message { base_observation with running_keeper_fiber_count = 2 }
  in
  check bool "namespace state present" true
    (contains ~needle:"### Namespace State" user);
  check bool "running keeper label present" true
    (contains ~needle:"- Running keeper fibers: 2" user);
  check bool "legacy active agents label absent" false
    (contains ~needle:"- Active agents:" user)

let test_profile_defaults_feed_identity_prompt () =
  with_repo_prompt_config @@ fun () ->
  let profile_defaults =
    {
      KTP.empty_keeper_profile_defaults with
      instructions = Some "soul instructions";
    }
  in
  let system =
    system_prompt ~profile_defaults base_observation
  in
  check bool "profile instructions in system prompt" true
    (contains ~needle:"Instructions:\nsoul instructions" system)

let test_no_goal_prompt_blocks_repo_creation_question () =
  with_repo_prompt_config @@ fun () ->
  let system = system_prompt base_observation in
  check bool "no active goal guidance present" true
    (contains ~needle:"You have no active goal" system);
  check bool "no repo creation question guard present" true
    (contains
       ~needle:"Do not ask the operator what repo, goal, or task to create"
       system)

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
          test_case "dashboard-only keeper has no section" `Quick
            test_dashboard_only_keeper_has_no_section;
          test_case "empty presence has no section" `Quick
            test_empty_presence_has_no_section;
          test_case "namespace state names running keeper fibers" `Quick
            test_namespace_state_names_running_keeper_fibers;
          test_case "profile defaults feed identity prompt" `Quick
            test_profile_defaults_feed_identity_prompt;
          test_case "no-goal prompt blocks repo creation question" `Quick
            test_no_goal_prompt_blocks_repo_creation_question;
        ] );
    ]
