(* RFC-0315 — wake-turn self-description.

   Pins the three prompt additions that let a woken keeper resume instead of
   acting lost:
   1. [current_task] renders a "Current Task" layer for the task whose claim
      admitted the turn (before: current_task_id only suppressed guidance).
   2. [turn_decision] threads the scheduler's real cycle decision into the
      wake-reason section, so stimulus-driven wakes render their reason.
   3. [?active_goal_summaries] renders goal titles next to ids.

   The third item once also pinned a self-direction directive for a keeper that
   holds goals, mirroring a no-goal branch. masc#26123 ("stop the runtime
   choosing the agent's next tool") removed both branches on purpose, so what is
   pinned here now is their absence. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt
module Turn = Masc.Keeper_turn
module Inputs = Masc.Keeper_world_observation_inputs

(* Repo-root sentinel: the one shared keeper prompt file. A sentinel that no
   longer exists makes [repo_root] fall back to the dune sandbox cwd, which
   loads an empty prompt registry and turns every shared-contract assertion
   below into a comparison of two empty blocks. *)
let has_repo_prompts root =
  Sys.file_exists (Filename.concat root "config/prompts/keeper.system.md")

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
      f ())

let base_observation : WO.world_observation =
  {
    pending_messages = [];
    pending_board_events = [];
    idle_seconds = 0;
    active_goals = [];
    unclaimed_task_count = 0;
    claimable_task_count = 0;
    failed_task_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_revision = Some 1;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
    connected_surface_failures = [];
    own_recent_board_posts = [];
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

let prompt_config = lazy (Masc.Workspace.default_config "/tmp/unused")

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
    else if Sys.file_exists (Filename.concat dir "config/prompts")
    then Some dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else find_root parent (hops + 1)
  in
  match find_root original_cwd 0 with
  | None ->
      Alcotest.fail
        "could not locate repo root (config/prompts) from test cwd"
  | Some root ->
      Unix.putenv "MASC_CONFIG_DIR" (Filename.concat root "config");
      Config_dir_resolver.reset ()

let contains ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  loop 0

(* Prose assertions match a sentence, not a line. The prompt assets are
   hard-wrapped markdown, so a needle that spans a wrap point fails on a space
   the file writes as a newline — masc#26823 re-wrapped the merged asset and
   broke an assertion whose sentence was still there, word for word. Collapse
   runs of whitespace on both sides so re-wrapping prose stays invisible here
   while deleting the sentence still fails. *)
let collapse_whitespace text =
  let buf = Buffer.create (String.length text) in
  let in_space = ref false in
  String.iter
    (fun c ->
      match c with
      | ' ' | '\t' | '\n' | '\r' ->
        if not !in_space then Buffer.add_char buf ' ';
        in_space := true
      | c ->
        Buffer.add_char buf c;
        in_space := false)
    text;
  Buffer.contents buf
;;

let contains_prose ~needle haystack =
  contains ~needle:(collapse_whitespace needle) (collapse_whitespace haystack)
;;

let count_occurrences ~needle haystack =
  let needle_length = String.length needle in
  let haystack_length = String.length haystack in
  let rec loop offset count =
    if needle_length = 0 || offset + needle_length > haystack_length then count
    else if String.sub haystack offset needle_length = needle
    then loop (offset + needle_length) (count + 1)
    else loop (offset + 1) count
  in
  loop 0 0

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
  let turn_decision =
    Option.value
      turn_decision
      ~default:(WO.keeper_cycle_decision ~meta observation)
  in
  let current_task =
    match current_task with
    | Some task -> Inputs.Current_task task
    | None -> Inputs.No_current_task
  in
  let { Prompt.world_state = user; _ } =
    Prompt.build_prompt ~meta ~config:(Lazy.force prompt_config) ~turn_decision
      ~current_task ?active_goal_summaries ~observation ()
  in
  user

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
  (* RFC-0365: the line carries the note's author, because a handoff can now
     survive an ownership change and an unattributed first-person account
     reads as the holder's own recollection. This fixture records neither
     [updated_by] nor [updated_at], so the absence is stated rather than
     omitted. *)
  check bool "handoff summary with attribution" true
    (contains
       ~needle:"- Prior handoff (unattributed): lexer done, parser half-wired"
       user);
  check bool "handoff next step" true
    (contains ~needle:"- Suggested next step: wire parser to store" user);
  check bool "no evidence line when the note records no refs" false
    (contains ~needle:"- Handoff evidence:" user);
  (* masc#24651 cut the "continue it or release it with a handoff summary"
     directive from this section; masc#26123 then made not choosing the agent's
     next action the standing policy. The section states what is held and what
     the prior handoff said, and stops there. *)
  check bool "section does not direct the next action" false
    (contains ~needle:"release it with a handoff summary" user)

let test_current_task_section_absent_without_task () =
  let user = user_message base_observation in
  check bool "no section without current task" false
    (contains ~needle:"### Current Task" user)

let task_id_exn value =
  match Keeper_id.Task_id.of_string value with
  | Ok task_id -> task_id
  | Error message -> fail message

let test_current_task_unavailable_is_explicit () =
  let task_id = task_id_exn "task-42" in
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let { Prompt.world_state; _ } =
    Prompt.build_prompt ~meta ~config:(Lazy.force prompt_config)
      ~turn_decision:decision
      ~current_task:
        (Inputs.Current_task_unavailable
           { task_id; error = "primary and recovery backlog decode failed" })
      ~observation:base_observation ()
  in
  check bool "task id remains visible" true
    (contains ~needle:"Task task-42 could not be observed" world_state);
  check bool "unavailable is not rendered as absent" true
    (contains ~needle:"does not mean the task is absent" world_state);
  check bool "storage error is not prompt content" false
    (contains ~needle:"primary and recovery backlog decode failed" world_state)

let test_current_task_missing_is_explicit () =
  let task_id = task_id_exn "task-42" in
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let { Prompt.world_state; _ } =
    Prompt.build_prompt ~meta ~config:(Lazy.force prompt_config)
      ~turn_decision:decision
      ~current_task:(Inputs.Current_task_missing { task_id; recovery = None })
      ~observation:base_observation ()
  in
  check bool "dangling id remains visible" true
    (contains ~needle:"references task-42" world_state);
  check bool "missing record forbids invented details" true
    (contains ~needle:"Do not infer or invent task details" world_state)

let test_recovered_current_task_is_non_authoritative () =
  let recovered_task : Masc_domain.task =
    make_task ~task_status:(Masc_domain.Todo : Masc_domain.task_status) ()
  in
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let recovery : Masc.Workspace.backlog_recovery =
    { recovery_path = "/tmp/backlog.last-good"; primary_error = "decode failed" }
  in
  let { Prompt.world_state; _ } =
    Prompt.build_prompt ~meta ~config:(Lazy.force prompt_config)
      ~turn_decision:decision
      ~current_task:
        (Inputs.Recovered_current_task { task = recovered_task; recovery })
      ~observation:base_observation ()
  in
  check bool "recovery is not asserted as held authority" false
    (contains ~needle:"Current Task (held by you)" world_state);
  check bool "recovery authority is explicit" true
    (contains
       ~needle:"Current Task (recovery observation; non-authoritative)"
       world_state);
  check bool "mutation authority is forbidden" true
    (contains ~needle:"Do not use this recovery observation as mutation authority" world_state);
  check bool "primary parser error is not prompt content" false
    (contains ~needle:"decode failed" world_state)

let test_direct_turn_reuses_current_task_context () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.InProgress
           { assignee = "wake-context-keeper"; started_at = "2026-07-07T01:00:00Z" })
      ~handoff_context:
        (Some
           {
             summary = "parser is ready for a direct reply";
             reason = None;
             next_step = Some "answer with the current parser status";
             failure_mode = None;
             reclaim_policy = None;
             evidence_refs = [];
             updated_at = None;
             updated_by = None;
           })
      ()
  in
  let context =
    Turn.For_testing.direct_turn_dynamic_context
      ~current_task:(Inputs.Current_task task)
      ~recent_direct_conversation_text:"recent owner message"
      ~worktree_text:"worktree state"
      ~telemetry_feedback_text:"telemetry state"
      ~turn_instructions_text:"turn instructions"
  in
  check int "current task is injected exactly once" 1
    (count_occurrences
       ~needle:"### Current Task (held by you)"
       context);
  check bool "held task id and title" true
    (contains ~needle:"task-42 — Wire the wake-turn context" context);
  check bool "handoff is available to direct reply" true
    (contains ~needle:"parser is ready for a direct reply" context);
  check bool "other fresh direct context is preserved" true
    (contains ~needle:"recent owner message" context)

let test_direct_turn_has_no_synthetic_task_context () =
  let context =
    Turn.For_testing.direct_turn_dynamic_context
      ~current_task:Inputs.No_current_task
      ~recent_direct_conversation_text:"recent owner message"
      ~worktree_text:""
      ~telemetry_feedback_text:""
      ~turn_instructions_text:""
  in
  check bool "no held task means no synthetic task context" false
    (contains ~needle:"### Current Task" context);
  check string "non-task context remains" "recent owner message" context

let test_direct_and_autonomous_share_system_prompt () =
  with_repo_prompt_config @@ fun () ->
  let decision = WO.keeper_cycle_decision ~meta base_observation in
  let { Prompt.system_prompt = autonomous_system_prompt; _ } =
    Prompt.build_prompt
      ~meta
      ~config:(Lazy.force prompt_config)
      ~turn_decision:decision
      ~current_task:Inputs.No_current_task
      ~observation:base_observation
      ()
  in
  let base_system_prompt =
    Masc.Keeper_run_context.build_base_system_prompt
      ~config:(Masc.Workspace.default_config "/tmp/unused")
      ~profile_defaults:
        Masc.Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~meta
  in
  (* Direct and autonomous turns share one system prompt outright: the
     channel-specific block that used to be appended for direct_reply was the
     last split between them and no longer exists, so the base prompt IS the
     contract for both entrypoints. *)
  check string
    "stable contract is byte-identical across turn entrypoints"
    autonomous_system_prompt
    base_system_prompt;
  (* The discovery sentence this used to match was cut in masc#26579; the
     policy it stated — an unregistered or unavailable checkout is handled
     explicitly, and absent evidence blocks rather than licenses a guess —
     is now stated in the merged [keeper.system] body. *)
  check bool "shared contract carries repository checkout policy" true
    (contains_prose
       ~needle:"handle a behind, diverged, dirty, unregistered, or unavailable"
       base_system_prompt);
  check bool "shared contract refuses to infer checkout state" true
    (contains_prose
       ~needle:"Missing, ambiguous, or stale checkout evidence is a blocker"
       base_system_prompt)

let test_unresolved_goal_keeps_one_stable_safety_contract () =
  with_repo_prompt_config @@ fun () ->
  let meta_with_goal =
    meta_of_json
      (`Assoc
        [
          ("name", `String "wake-context-keeper");
          ("trace_id", `String "test-trace-wake-context");
          ("active_goal_ids", `List [ `String "missing-goal" ]);
        ])
  in
  let config = Masc.Workspace.default_config "/tmp/unused" in
  let active_goal_summaries =
    Prompt.active_goal_summaries ~config ~meta:meta_with_goal
  in
  let decision = WO.keeper_cycle_decision ~meta:meta_with_goal base_observation in
  let { Prompt.system_prompt = autonomous_system_prompt; _ } =
    Prompt.build_prompt
      ~meta:meta_with_goal
      ~config:(Lazy.force prompt_config)
      ~active_goal_summaries
      ~turn_decision:decision
      ~current_task:Inputs.No_current_task
      ~observation:base_observation
      ()
  in
  let base_system_prompt =
    Masc.Keeper_run_context.build_base_system_prompt
      ~config
      ~profile_defaults:
        Masc.Keeper_types_profile_defaults.empty_keeper_profile_defaults
      ~meta:meta_with_goal
  in
  check string
    "unresolved goal does not split direct and autonomous prompts"
    base_system_prompt
    autonomous_system_prompt;
  check bool "unresolved goal remains as a bare id" true
    (contains ~needle:"- missing-goal\n" base_system_prompt);
  check bool "identity block is preserved" true
    (contains ~needle:"<identity>" base_system_prompt);
  (* The shared block is one [<system>] element now. Its former
     [<world>]/[<capabilities>] tags are gone, so the two contracts they
     wrapped are pinned by their own sentences instead of by a tag name. *)
  check bool "shared system block is preserved" true
    (contains ~needle:"<system>" base_system_prompt);
  check bool "ownership contract is preserved" true
    (contains
       ~needle:"MASC owns Board, Task, Goal, Schedule"
       base_system_prompt);
  check bool "capability contract is preserved" true
    (contains
       ~needle:"The active typed schema is the sole callable catalog"
       base_system_prompt)

(* --- 2. Threaded turn decision --- *)

let test_threaded_stimulus_decision_renders_wake_reason () =
  (* A bootstrap event-queue stimulus on an otherwise empty world: the real
     scheduler decision knows the trigger; a local recompute cannot. *)
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

let test_bootstrap_stimulus_keeps_reactive_post_action () =
  let decision =
    WO.keeper_cycle_decision
      ~event_queue_triggers:[ WO.Bootstrap_stimulus ]
      ~meta
      base_observation
  in
  match
    Masc.Keeper_unified_turn_success.For_testing.post_action_of_channel
      decision.WO.channel
  with
  | Masc.Keeper_unified_turn_success.For_testing.Assign_task -> ()
  | Masc.Keeper_unified_turn_success.For_testing.Empty_queue_sleep ->
    Alcotest.fail
      "bootstrap stimulus must not be reclassified from reactive to scheduled"

let test_preview_does_not_invent_wake_reason () =
  let preview_meta =
    { meta with
      Masc.Keeper_meta_contract.name = "preview-must-not-emit-turn-metrics"
    }
  in
  let segment_metric = Keeper_metrics.(to_string PromptSegmentBytes) in
  let segment_labels =
    [ "keeper", preview_meta.name; "segment", "system_prompt" ]
  in
  let instruction_hash_metric =
    Keeper_metrics.(to_string KeeperTurnInstructionHash)
  in
  check bool "fixture has no preview segment metric" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          segment_metric
          ~labels:segment_labels
          ()));
  check bool "fixture has no preview hash metric" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          instruction_hash_metric
          ~labels:[ "keeper", preview_meta.name ]
          ()));
  let { Prompt.world_state; _ } =
    Prompt.build_prompt_preview
      ~meta:preview_meta
      ~config:(Lazy.force prompt_config)
      ~current_task:Inputs.No_current_task
      ~observation:base_observation
      ()
  in
  check bool "preview has no scheduler trigger" false
    (contains ~needle:"### Autonomous Trigger" world_state);
  check bool "preview does not emit segment metric" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          segment_metric
          ~labels:segment_labels
          ()));
  check bool "preview does not emit instruction hash" true
    (Option.is_none
       (Otel_metric_store_core.get_metric_value
          instruction_hash_metric
          ~labels:[ "keeper", preview_meta.name ]
          ()))

(* --- 3. Goal titles + self-direction parity --- *)

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

let test_goal_holder_gets_self_direction_directive () =
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
  let goal_turn_decision =
    WO.keeper_cycle_decision ~meta:meta_with_goal base_observation
  in
  let { Prompt.system_prompt = system; _ } =
    Prompt.build_prompt ~meta:meta_with_goal ~config:(Lazy.force prompt_config)
      ~turn_decision:goal_turn_decision ~current_task:Inputs.No_current_task
      ~observation:base_observation ()
  in
  (* masc#26123 removed both self-direction branches. The prompt states the
     goals a keeper holds and leaves the choice of next action to it, so the
     directive that used to accompany them must not come back. *)
  check bool "no self-direction directive for a goal holder" false
    (contains ~needle:"advance one of your active" system);
  check bool "no defer directive either" false
    (contains ~needle:"Deferring is a valid choice" system);
  check bool "the goal itself is still named" true
    (contains ~needle:"goal-x" system);
  let no_goal_turn_decision =
    WO.keeper_cycle_decision ~meta base_observation
  in
  let { Prompt.system_prompt = no_goal_system; _ } =
    Prompt.build_prompt ~meta ~config:(Lazy.force prompt_config)
      ~turn_decision:no_goal_turn_decision ~current_task:Inputs.No_current_task
      ~observation:base_observation ()
  in
  check bool "no-goal branch directs nothing either" false
    (contains ~needle:"You have no active goal" no_goal_system);
  check bool "and carries no goal-holder directive" false
    (contains ~needle:"advance one of your active" no_goal_system)

let () =
  init_prompt_config_for_tests ();
  init_runtime_default_for_tests ();
  run "keeper_wake_turn_context"
    [
      ( "current task layer",
        [
          test_case "renders id, status, handoff, directive" `Quick
            test_current_task_section_renders;
          test_case "absent without a held task" `Quick
            test_current_task_section_absent_without_task;
          test_case "unavailable backlog remains explicit" `Quick
            test_current_task_unavailable_is_explicit;
          test_case "dangling task id remains explicit" `Quick
            test_current_task_missing_is_explicit;
          test_case "recovery task is explicitly non-authoritative" `Quick
            test_recovered_current_task_is_non_authoritative;
          test_case "direct reply receives the held task and handoff" `Quick
            test_direct_turn_reuses_current_task_context;
          test_case "direct reply invents no task when none is held" `Quick
            test_direct_turn_has_no_synthetic_task_context;
          test_case "direct and autonomous turns share the stable contract"
            `Quick
            test_direct_and_autonomous_share_system_prompt;
          test_case "unresolved goal keeps one stable safety contract" `Quick
            test_unresolved_goal_keeps_one_stable_safety_contract;
        ] );
      ( "threaded turn decision",
        [
          test_case "stimulus decision renders wake reason" `Quick
            test_threaded_stimulus_decision_renders_wake_reason;
          test_case "bootstrap keeps reactive post-action" `Quick
            test_bootstrap_stimulus_keeps_reactive_post_action;
          test_case "preview invents no wake reason" `Quick
            test_preview_does_not_invent_wake_reason;
        ] );
      ( "goal titles and parity directive",
        [
          test_case "summaries render titles, unresolved ids stay bare" `Quick
            test_goal_summaries_render_titles;
          test_case "partial summaries preserve missing goal ids" `Quick
            test_partial_goal_summaries_preserve_missing_ids;
          test_case "goal holder gets self-direction directive" `Quick
            test_goal_holder_gets_self_direction_directive;
        ] );
    ]
