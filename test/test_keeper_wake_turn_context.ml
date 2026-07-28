(* RFC-0315 — wake-turn self-description.

   Pins the three prompt additions that let a woken keeper resume instead of
   acting lost:
   1. [?current_task] renders a "Current Task" layer for the task whose claim
      admitted the turn (before: current_task_id only suppressed guidance).
   2. [?turn_decision] threads the scheduler's real cycle decision into the
      wake-reason section (before: build_prompt recomputed with
      reactive_wake=false / event_queue_triggers=[], so stimulus-driven wakes
      rendered no reason).
   3. [?active_goal_summaries] renders goal titles next to ids without adding
      a runtime-authored next-action directive. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt

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
      Prompt_registry.clear ();
      match original_config with
      | Some config_dir when String.trim config_dir <> "" ->
        Prompt_registry.set_markdown_dir
          (Filename.concat config_dir "prompts");
        Masc.Prompt_defaults.init ();
        Masc.Keeper_prompt_external.reset_cache ()
      | Some _ | None -> ())
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
    pending_message_backlog = { remaining_count = 0; latest_pending = None };
    pending_board_events = [];
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
    connected_surface_failures = [];
  }

let meta_of_json json =
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)

let meta : Masc.Keeper_meta_contract.keeper_meta =
  meta_of_json
    (`Assoc
      [
        ("name", `String "wake-context-keeper");
        ("trace_id", `String "test-trace-wake-context");
      ])

(* Same throwaway runtime default as test_keeper_surface_presence_prompt:
   the Autonomous Trigger section consults the default runtime (RFC-0206). *)
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
  let path = Filename.temp_file "wake_turn_context_runtime_" ".toml" in
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

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  loop 0

let with_malformed_unified_prompt f =
  let prompts_dir = Filename.temp_dir "keeper-unified-render-failure-" "" in
  let prompt_path =
    Filename.concat prompts_dir "keeper.unified.system.md"
  in
  Out_channel.with_open_text prompt_path (fun channel ->
    output_string channel
      "---\n\
       description: malformed keeper unified prompt\n\
       category: keeper\n\
       template_variables: [identity_header, unknown_variable]\n\
       ---\n\
       {{identity_header}}\n\
       {{unknown_variable}}\n");
  Fun.protect
    ~finally:(fun () ->
      Prompt_registry.clear ();
      Sys.remove prompt_path;
      Unix.rmdir prompts_dir)
    (fun () ->
      Prompt_registry.clear ();
      Prompt_registry.set_markdown_dir prompts_dir;
      f ())

let test_unified_template_failure_uses_closed_safety_fallback () =
  with_repo_prompt_config @@ fun () ->
  with_malformed_unified_prompt @@ fun () ->
  let sentinel = "SENTINEL_UNIFIED_INSTRUCTIONS_7f4a" in
  let degraded_meta = { meta with instructions = sentinel } in
  let { Prompt.system_prompt; _ } =
    Prompt.build_prompt
      ~meta:degraded_meta
      ~base_path:"/tmp/unused"
      ~observation:base_observation
      ()
  in
  check bool "identity survives render failure" true
    (contains
       ~needle:"You are wake-context-keeper, a keeper agent."
       system_prompt);
  check bool "instructions survive render failure" true
    (contains ~needle:sentinel system_prompt);
  check bool "raw unresolved placeholder is never delivered" false
    (contains ~needle:"{{unknown_variable}}" system_prompt);
  check bool "fallback makes configuration degradation explicit" true
    (contains ~needle:"## Prompt configuration degraded" system_prompt);
  check bool "fallback keeps typed tool authority" true
    (contains ~needle:"active typed tool schema" system_prompt)

let test_template_syntax_inside_instructions_is_literal_content () =
  with_repo_prompt_config @@ fun () ->
  let literal = "Document the literal {{example_variable}} token." in
  let literal_meta = { meta with instructions = literal } in
  let { Prompt.system_prompt; _ } =
    Prompt.build_prompt
      ~meta:literal_meta
      ~base_path:"/tmp/unused"
      ~observation:base_observation
      ()
  in
  check bool "injected instruction remains exact" true
    (contains ~needle:literal system_prompt);
  check bool "literal content does not trigger degraded fallback" false
    (contains ~needle:"## Prompt configuration degraded" system_prompt)

let make_task ?(handoff_context = None) ~task_status () : Masc_domain.task =
  {
    id = "task-42";
    title = "Wire the wake-turn context";
    description = "test task";
    task_status;
    priority = 3;
    files = [];
    created_at = "2026-07-07T00:00:00Z";
    created_by = None;
    predecessor_task_id = None;
    contract = None;
    handoff_context;
    cycle_count = 0;
    reclaim_policy = None;
    do_not_reclaim_reason = None;
  }

let user_message ?turn_decision ?current_task ?active_goal_summaries observation =
  let { Prompt.world_state = user; _ } =
    Prompt.build_prompt ~meta ~base_path:"/tmp/unused" ?turn_decision
      ?current_task ?active_goal_summaries ~observation ()
  in
  user

let test_pending_backlog_signal_renders_latest_context () =
  let module Scope = Masc.Keeper_world_observation_message_scope in
  let admitted : Scope.pending_message =
    { message_id = "a"
    ; speaker = "owner"
    ; content = "initial request"
    ; kind = Scope.Mention
    }
  in
  let correction : Scope.pending_message =
    { message_id = "b"
    ; speaker = "owner"
    ; content = "correction before snapshot"
    ; kind = Scope.Mention
    }
  in
  let observation =
    { base_observation with
      pending_messages = [ admitted ]
    ; pending_message_backlog =
        { remaining_count = 1; latest_pending = Some correction }
    }
  in
  let rendered = user_message observation in
  check bool "admitted row renders" true
    (contains ~needle:"initial request" rendered);
  check bool "remaining count renders" true
    (contains ~needle:"1 additional pending row(s)" rendered);
  check bool "latest correction renders without admission" true
    (contains ~needle:"correction before snapshot" rendered)
;;

(* --- 1. Current Task layer --- *)

let test_current_task_section_renders () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.InProgress
           { assignee = "wake-context-keeper"; started_at = "2026-07-07T01:00:00Z" })
      ~handoff_context:
        (Some
           {
             summary = "lexer done, parser half-wired";
             reason = None;
             next_step = Some "wire parser to store";
             failure_mode = None;
             reclaim_policy = None;
             evidence_refs = [];
             updated_at = None;
             updated_by = None;
           })
      ()
  in
  let user = user_message ~current_task:task base_observation in
  check bool "section header" true
    (contains ~needle:"### Current Task (held by you)" user);
  check bool "task id and title" true
    (contains ~needle:"- task-42 — Wire the wake-turn context" user);
  check bool "status line" true
    (contains ~needle:"in progress (wake-context-keeper) since 2026-07-07T01:00:00Z" user);
  check bool "handoff summary" true
    (contains ~needle:"- Prior handoff: lexer done, parser half-wired" user);
  check bool "handoff next step" true
    (contains ~needle:"- Suggested next step: wire parser to store" user);
  check bool "runtime adds no continue-or-release directive" false
    (contains ~needle:"release it with a handoff summary" user)

let test_current_task_section_absent_without_task () =
  let user = user_message base_observation in
  check bool "no section without current task" false
    (contains ~needle:"### Current Task" user)

(* --- 2. Threaded turn decision --- *)

let test_threaded_stimulus_decision_renders_wake_reason () =
  (* A bootstrap event-queue stimulus on an otherwise empty world: the real
     scheduler decision knows the trigger, the legacy recompute cannot. *)
  let decision =
    WO.keeper_cycle_decision
      ~event_queue_triggers:[ WO.Bootstrap_stimulus ]
      ~meta base_observation
  in
  check bool "fixture: stimulus decision runs" true decision.WO.should_run;
  let threaded = user_message ~turn_decision:decision base_observation in
  check bool "wake-reason section present" true
    (contains ~needle:"### Autonomous Trigger" threaded);
  check bool "reactive scheduler line" true
    (contains ~needle:"- Scheduler: reactive turn (external stimulus)." threaded);
  check bool "bootstrap reason listed" true
    (contains ~needle:"bootstrap" threaded)

let test_unthreaded_recompute_renders_no_reason_on_empty_world () =
  (* Same empty world without the threaded decision: the recompute sees no
     trigger, so no wake-reason section renders — the pre-RFC-0315 blindness
     this change removes for stimulus wakes. *)
  let user = user_message base_observation in
  check bool "no reactive scheduler line" false
    (contains ~needle:"- Scheduler: reactive turn (external stimulus)." user)

(* --- 3. Goal titles without runtime-authored next-action policy --- *)

let test_goal_summaries_render_titles () =
  let observation = { base_observation with active_goals = [ "goal-x" ] } in
  let with_titles =
    user_message
      ~active_goal_summaries:[ ("goal-x", "Improve wake context") ]
      observation
  in
  check bool "id and title" true
    (contains ~needle:"- goal-x — Improve wake context" with_titles);
  let bare = user_message observation in
  check bool "bare id" true (contains ~needle:"- goal-x" bare);
  check bool "bare id has no title" false
    (contains ~needle:"Improve wake context" bare)

let test_partial_goal_summaries_preserve_missing_ids () =
  let observation =
    { base_observation with active_goals = [ "goal-a"; "goal-b" ] }
  in
  let user =
    user_message
      ~active_goal_summaries:[ ("goal-a", "Improve wake context") ]
      observation
  in
  check bool "header keeps full active-goal count" true
    (contains ~needle:"### Active Goals (2)" user);
  check bool "resolved goal title renders" true
    (contains ~needle:"- goal-a — Improve wake context" user);
  check bool "missing title falls back to bare id" true
    (contains ~needle:"- goal-b" user)

let test_goal_context_does_not_choose_the_next_action () =
  with_repo_prompt_config @@ fun () ->
  let meta_with_goal =
    meta_of_json
      (`Assoc
        [
          ("name", `String "wake-context-keeper");
          ("trace_id", `String "test-trace-wake-context");
          ("active_goal_ids", `List [ `String "goal-x" ]);
        ])
  in
  let { Prompt.system_prompt = system; _ } =
    Prompt.build_prompt ~meta:meta_with_goal ~base_path:"/tmp/unused"
      ~observation:base_observation ()
  in
  check bool "primary goal remains observable" true
    (contains ~needle:"Primary goal: goal-x" system);
  check bool "goal-holder next-action directive is absent" false
    (contains ~needle:"advance one of your active" system);
  check bool "runtime does not choose deferral policy" false
    (contains ~needle:"Deferring is a valid choice" system);
  let { Prompt.system_prompt = no_goal_system; _ } =
    Prompt.build_prompt ~meta ~base_path:"/tmp/unused"
      ~observation:base_observation ()
  in
  check bool "missing primary goal remains observable" true
    (contains
       ~needle:"Primary goal: (no valid active goal — awaiting assignment)"
       no_goal_system);
  check bool "no-goal next-action menu is absent" false
    (contains ~needle:"You have no active goal" no_goal_system);
  check bool "goal-holder directive is absent without goals" false
    (contains ~needle:"advance one of your active" no_goal_system)

let () =
  init_prompt_config_for_tests ();
  init_runtime_default_for_tests ();
  run "keeper_wake_turn_context"
    [
      ( "prompt render failure",
        [
          test_case
            "unified template failure uses closed safety fallback"
            `Quick
            test_unified_template_failure_uses_closed_safety_fallback;
          test_case
            "template syntax in instructions stays literal"
            `Quick
            test_template_syntax_inside_instructions_is_literal_content;
        ] );
      ( "current task layer",
        [
          test_case "renders id, status, and handoff facts" `Quick
            test_current_task_section_renders;
          test_case "absent without a held task" `Quick
            test_current_task_section_absent_without_task;
        ] );
      ( "pending message backlog",
        [
          test_case "renders remaining count and latest context" `Quick
            test_pending_backlog_signal_renders_latest_context;
        ] );
      ( "threaded turn decision",
        [
          test_case "stimulus decision renders wake reason" `Quick
            test_threaded_stimulus_decision_renders_wake_reason;
          test_case "unthreaded recompute stays blind on empty world" `Quick
            test_unthreaded_recompute_renders_no_reason_on_empty_world;
        ] );
      ( "goal titles and neutral goal context",
        [
          test_case "summaries render titles, unresolved ids stay bare" `Quick
            test_goal_summaries_render_titles;
          test_case "partial summaries preserve missing goal ids" `Quick
            test_partial_goal_summaries_preserve_missing_ids;
          test_case "runtime does not choose the next action" `Quick
            test_goal_context_does_not_choose_the_next_action;
        ] );
    ]
