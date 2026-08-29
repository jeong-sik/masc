(** Wake-turn task, trigger, and goal context contracts. *)

open Alcotest

module WO = Masc.Keeper_world_observation
module Prompt = Masc.Keeper_unified_prompt
module Turn = Masc.Keeper_turn
module Inputs = Masc.Keeper_world_observation_inputs

let skill_reference name revision =
  let source_id =
    match Skill_source_config.source_id_of_string "project-masc" with
    | Ok source_id -> source_id
    | Error detail -> fail detail
  in
  let package_id =
    match Skill_reference.package_id_of_directory name with
    | Ok package_id -> package_id
    | Error _ -> failf "invalid Skill package fixture %S" name
  in
  let content_revision =
    match Skill_reference.content_revision_of_string (String.make 64 revision) with
    | Ok content_revision -> content_revision
    | Error _ -> fail "invalid Skill revision fixture"
  in
  Skill_reference.make
    ~identity:(Skill_reference.make_identity ~source_id ~package_id ~name)
    ~content_revision
;;

(* The shared Keeper prompt identifies the repository root from a Dune sandbox. *)
let has_repo_prompts root =
  Sys.file_exists (Filename.concat root "config/prompts/keeper.md")

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
    claimable_tasks = [];
    held_task_skills = [];
    failed_task_count = 0;
    scheduled_automation = WO.empty_scheduled_automation_observation;
    backlog_revision = Some 1;
    running_keeper_fiber_count = 0;
    connected_surfaces = [];
    connected_surface_failures = [];
    own_recent_board_posts = [];
    fleet_messages = [];
    own_recent_actions = [];
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

(* The autonomous trigger section requires a configured default runtime. *)
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

(* Normalize wrapping so assertions match prompt sentences rather than lines. *)
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
    execution_links = Masc_domain.no_execution_links;
    do_not_reclaim_reason = None;
    skills = [];
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

(* --- Own Recent Actions: arguments ride on refusals --- *)

let action_turn turn_id calls : Masc.Keeper_own_recent_actions.turn =
  { turn_id; calls }
;;

let call ~tool ~input ~outcome : Masc.Keeper_own_recent_actions.call =
  { Masc.Keeper_own_recent_actions.tool; input; outcome }
;;

let own_recent_actions_section body =
  let marker = "### Your Recent Actions" in
  match Astring.String.find_sub ~sub:marker body with
  | None -> ""
  | Some start ->
    let rest = String.sub body start (String.length body - start) in
    (match Astring.String.find_sub ~sub:"\n###" rest with
     | None -> rest
     | Some stop -> String.sub rest 0 stop)
;;

(* The live shape that starved keeper [analyst] on 2026-08-23: turns whose
   successful calls carry large argument objects. 1,312 successes carried
   538,743 bytes against 20 refusals carrying 6,417. *)
let test_successful_call_arguments_are_not_replayed () =
  let big = String.make 4000 'x' in
  let observation =
    { base_observation with
      WO.own_recent_actions =
        [ action_turn
            360
            (List.init 20 (fun i ->
               call
                 ~tool:"keeper_tool_execute"
                 ~input:(Printf.sprintf "{\"i\":%d,\"payload\":\"%s\"}" i big)
                 ~outcome:Masc.Keeper_own_recent_actions.Ok_call))
        ]
    }
  in
  let body = with_repo_prompt_config (fun () -> user_message observation) in
  let section = own_recent_actions_section body in
  check bool "the calls are still listed" true
    (Option.is_some
       (Astring.String.find_sub ~sub:"[turn 360] keeper_tool_execute -> ok" section));
  check bool
    (Printf.sprintf "no argument body is replayed (section is %d bytes)"
       (String.length section))
    true
    (Option.is_none (Astring.String.find_sub ~sub:big section))
;;

let test_refused_call_keeps_its_arguments () =
  let payload = "{\"task_id\":\"task-471\",\"note\":\"needs-approval\"}" in
  let observation =
    { base_observation with
      WO.own_recent_actions =
        [ action_turn
            361
            [ call
                ~tool:"keeper_task_done"
                ~input:payload
                ~outcome:(Masc.Keeper_own_recent_actions.Failed_call (Some "not verified"))
            ]
        ]
    }
  in
  let body = with_repo_prompt_config (fun () -> user_message observation) in
  let section = own_recent_actions_section body in
  check bool "the refused call keeps what was sent" true
    (Option.is_some (Astring.String.find_sub ~sub:payload section));
  check bool "and says why it was refused" true
    (Option.is_some (Astring.String.find_sub ~sub:"REJECTED: not verified" section))
;;

(* The digest is the salience fix: a keeper re-read the same nonexistent paths
   every autonomous turn on 2026-08-28 while the refusals were already inside
   this window, buried in the row matrix. Five turns of the same rejected
   read must surface as one counted row, ahead of the rows. *)
let test_failure_digest_dedupes_and_counts () =
  let path = "{\"path\":\"/repos/masc/lib/keeper/keeper_sandbox_control.ml\"}" in
  let observation =
    { base_observation with
      WO.own_recent_actions =
        List.init 5 (fun i ->
            action_turn
              (370 + i)
              [
                call
                  ~tool:"tool_read_file"
                  ~input:path
                  ~outcome:
                    (Masc.Keeper_own_recent_actions.Failed_call
                       (Some "docker_cat_failed: No such file or directory"));
              ])
    }
  in
  let body = with_repo_prompt_config (fun () -> user_message observation) in
  let section = own_recent_actions_section body in
  check bool "digest heading present" true
    (Option.is_some (Astring.String.find_sub ~sub:"Rejected already" section));
  check bool "the same rejected read is counted once" true
    (Option.is_some (Astring.String.find_sub ~sub:" ×5 " section));
  check bool "and keeps its newest refusal reason" true
    (Option.is_some
       (Astring.String.find_sub
          ~sub:"docker_cat_failed: No such file or directory" section))
;;

let test_no_digest_without_failures () =
  let observation =
    { base_observation with
      WO.own_recent_actions =
        [ action_turn
            380
            [ call
                ~tool:"masc_board_list"
                ~input:"{}"
                ~outcome:Masc.Keeper_own_recent_actions.Ok_call ]
        ]
    }
  in
  let body = with_repo_prompt_config (fun () -> user_message observation) in
  let section = own_recent_actions_section body in
  check bool "no digest heading without refusals" true
    (Option.is_none (Astring.String.find_sub ~sub:"Rejected already" section))
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
  (* An unattributed handoff stays explicit when author metadata is absent. *)
  check bool "handoff summary with attribution" true
    (contains
       ~needle:"- Prior handoff (unattributed): lexer done, parser half-wired"
       user);
  check bool "handoff next step" true
    (contains ~needle:"- Suggested next step: wire parser to store" user);
  check bool "no evidence line when the note records no refs" false
    (contains ~needle:"- Handoff evidence:" user)

(* task-364: the other held tasks' skills get their own lines. *)
let test_held_task_skills_section_renders () =
  let user =
    with_repo_prompt_config @@ fun () ->
    user_message
      { base_observation with
        held_task_skills =
          [ { Inputs.held_task_id = "task-364"
            ; held_skills =
                [ skill_reference "mission-snapshot" 'a'
                ; skill_reference "work-intake" 'b'
                ]
            }
          ]
      }
  in
  check bool "heading" true (contains ~needle:"### Skills Named by Tasks You Hold" user);
  check bool "line names the task and exact skills" true
    (contains ~needle:"task-364 (held by you) names exact Skill catalog rows: [{" user
     && contains ~needle:"\"name\":\"mission-snapshot\"" user
     && contains ~needle:"\"name\":\"work-intake\"" user);
  check bool "unprojected refs are explicitly unavailable" true
    (contains ~needle:"\"kind\":\"unavailable\"" user);
  check bool "unprojected refs do not invent keeper_skill" false
    (contains ~needle:"`keeper_skill`" user)

let test_held_task_skills_section_absent_without_held_tasks () =
  let user = user_message base_observation in
  check bool "no heading without held skills" false
    (contains ~needle:"Skills Named by Tasks You Hold" user)

(* The projection reads ownership off the tasks: held by this keeper, naming
   a skill, and not the current task. *)
let test_held_task_skills_projection () =
  let config = Lazy.force prompt_config in
  let assignee = meta.name in
  let held id ~by ~skills ~status =
    let task_status =
      match status with
      | `Claimed -> Masc_domain.Claimed { assignee = by; claimed_at = "2026-08-26T00:00:00Z" }
      | `In_progress -> Masc_domain.InProgress { assignee = by; started_at = "2026-08-26T00:00:00Z" }
    in
    { (make_task ~task_status ()) with id; skills }
  in
  let tasks =
    [ held "task-42" ~by:assignee ~skills:[ skill_reference "a" 'a' ] ~status:`In_progress
    ; held "task-43" ~by:assignee
        ~skills:[ skill_reference "b" 'b'; skill_reference "c" 'c' ] ~status:`Claimed
    ; held "task-44" ~by:"someone-else" ~skills:[ skill_reference "d" 'd' ] ~status:`Claimed
    ; held "task-45" ~by:assignee ~skills:[] ~status:`In_progress
    ; { (make_task ~task_status:Masc_domain.Todo ()) with
        id = "task-46"
      ; skills = [ skill_reference "e" 'e' ]
      }
    ]
  in
  let meta =
    { meta with
      current_task_id = Some (Keeper_id.Task_id.of_string "task-42" |> Result.get_ok) }
  in
  let projected = Inputs.held_task_skills_of_tasks ~config ~meta tasks in
  check (list string) "only the other held task that names skills"
    [ "task-43" ]
    (List.map (fun (h : Inputs.held_task_skills) -> h.held_task_id) projected);
  check (list string) "its skills in declaration order"
    [ "b"; "c" ]
    (List.concat_map
       (fun (h : Inputs.held_task_skills) ->
         List.map
           (fun (reference : Skill_reference.t) -> reference.identity.name)
           h.held_skills)
       projected);
  let meta = { meta with current_task_id = None } in
  check (list string) "without a current task both held tasks project"
    [ "task-42"; "task-43" ]
    (List.map (fun (h : Inputs.held_task_skills) -> h.held_task_id)
       (Inputs.held_task_skills_of_tasks ~config ~meta tasks))

let test_current_task_section_absent_without_task () =
  let user = user_message base_observation in
  check bool "no section without current task" false
    (contains ~needle:"### Current Task" user)

let task_id_exn value =
  match Keeper_id.Task_id.of_string value with
  | Ok task_id -> task_id
  | Error message -> fail message

let test_current_task_unavailable_is_explicit () =
  (* The needles assert the configured prose (config/prompts/
     keeper.observation.current_task_unobservable.md), so the repo prompt
     config must be loaded the way the passing siblings load it; without it
     the renderer falls back to different built-in wording. *)
  with_repo_prompt_config @@ fun () ->
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
  with_repo_prompt_config @@ fun () ->
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
  with_repo_prompt_config @@ fun () ->
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
      ~held_task_skills:[]
      ~task_skill_surfaces:[]
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

(* task-364: the direct-message lane carries the held tasks' skills even when
   no task is current, so an owner asking the keeper about the work it just
   claimed gets the same skill lines the scheduled lane renders. *)
let test_direct_turn_carries_held_task_skills () =
  let context =
    with_repo_prompt_config @@ fun () ->
    Turn.For_testing.direct_turn_dynamic_context
      ~current_task:Inputs.No_current_task
      ~held_task_skills:
        [ { Inputs.held_task_id = "task-364"
          ; held_skills = [ skill_reference "mission-snapshot" 'a' ]
          }
        ]
      ~task_skill_surfaces:[]
      ~recent_direct_conversation_text:"recent owner message"
      ~worktree_text:""
      ~telemetry_feedback_text:""
      ~turn_instructions_text:""
  in
  check bool "held skills heading" true
    (contains ~needle:"### Skills Named by Tasks You Hold" context);
  check bool "held exact skills line" true
    (contains ~needle:"task-364 (held by you) names exact Skill catalog rows: [{" context
     && contains ~needle:"\"name\":\"mission-snapshot\"" context);
  check bool "catalog row is conditional on this attempt's schema" true
    (contains ~needle:"only when that tool is present in the current attempt's tool schema" context
     && contains ~needle:"a runtime may suppress all tools" context);
  check bool "no synthetic current task" false (contains ~needle:"### Current Task" context)

let test_direct_turn_has_no_synthetic_task_context () =
  let context =
    Turn.For_testing.direct_turn_dynamic_context
      ~current_task:Inputs.No_current_task
      ~held_task_skills:[]
      ~task_skill_surfaces:[]
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
  (* Both turn entrypoints consume the same system prompt contract. *)
  check string
    "stable contract is byte-identical across turn entrypoints"
    autonomous_system_prompt
    base_system_prompt;
  check bool "shared contract keeps intended scope" true
    (contains_prose
       ~needle:"Deliver the current work at its intended scope"
       base_system_prompt);
  check bool "shared contract excludes unrelated work" true
    (contains_prose ~needle:"Do not add unrelated work" base_system_prompt);
  check bool "shared contract leads with the result" true
    (contains_prose ~needle:"lead with the result" base_system_prompt)

let test_open_goal_store_keeps_one_stable_safety_contract () =
  with_repo_prompt_config @@ fun () ->
  let meta_with_goal =
    meta_of_json
      (`Assoc
        [
          ("name", `String "wake-context-keeper");
          ("trace_id", `String "test-trace-wake-context");
        ])
  in
  let config = Masc.Workspace.default_config "/tmp/unused" in
  let active_goal_summaries =
    Prompt.active_goal_summaries_of_store ~config
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
  check bool "removed per-Keeper goal id is absent" false
    (contains ~needle:"- missing-goal\n" base_system_prompt);
  check bool "identity block is preserved" true
    (contains ~needle:"<identity>" base_system_prompt);
  (* The shared prompt remains the stable system prefix for both turn paths. *)
  check bool "shared system block is preserved" true
    (contains ~needle:"<system>" base_system_prompt);
  check bool "scope contract is preserved" true
    (contains
       ~needle:"Deliver the current work at its intended scope"
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

(* AwaitingVerification does not hold a claim, so its heading must not imply
   active ownership. *)
let test_submitted_task_heading_does_not_claim_a_hold () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.AwaitingVerification
           { assignee = "wake-context-keeper"
           ; started_at = "2026-07-07T01:00:00Z"
           ; submitted_at = "2026-07-07T02:00:00Z"
           ; verification_id = "vrf-task-42"
           })
      ()
  in
  let user = user_message ~current_task:task base_observation in
  check bool "not called held" false
    (contains ~needle:"Current Task (held by you)" user);
  check bool "the heading states what it is instead" true
    (contains
       ~needle:"### Current Task (submitted for verification; it does not hold your claim)"
       user);
  check bool "the row still carries the task" true
    (contains ~needle:"- task-42 — Wire the wake-turn context" user);
  check bool "and its status" true
    (contains ~needle:"awaiting verification (submitted 2026-07-07T02:00:00Z)" user)

let test_in_progress_task_heading_still_says_held () =
  let task =
    make_task
      ~task_status:
        (Masc_domain.InProgress
           { assignee = "wake-context-keeper"; started_at = "2026-07-07T01:00:00Z" })
      ()
  in
  let user = user_message ~current_task:task base_observation in
  check bool "a task actually held is still called held" true
    (contains ~needle:"### Current Task (held by you)" user)

(* --- 3. Goal titles --- *)

let test_goal_summaries_render_titles () =
  let observation = { base_observation with active_goals = [ "goal-x" ] } in
  let with_titles =
    user_message
      ~active_goal_summaries:
        [ { Prompt.summary_goal_id = "goal-x"
          ; summary_title = "Improve wake context"
          ; summary_phase = None
          }
        ]
      observation
  in
  check bool "id and title" true
    (contains ~needle:"- goal-x — Improve wake context" with_titles);
  let bare = user_message observation in
  check bool "bare id" true (contains ~needle:"- goal-x" bare);
  check bool "bare id has no title" false
    (contains ~needle:"Improve wake context" bare)

(* The heading and the list are read off one list, so the keeper is never told
   it holds goals the block does not name. *)
let test_goal_heading_counts_what_the_block_lists () =
  let observation =
    { base_observation with active_goals = [ "goal-a"; "goal-b" ] }
  in
  let user =
    user_message
      ~active_goal_summaries:
        [ { Prompt.summary_goal_id = "goal-a"
          ; summary_title = "Improve wake context"
          ; summary_phase = None
          }
        ]
      observation
  in
  check bool "heading counts the rendered goals" true
    (contains ~needle:"### Active Goals (1)" user);
  check bool "the rendered goal carries its title" true
    (contains ~needle:"- goal-a — Improve wake context" user);
  check bool "no goal is counted without being named" false
    (contains ~needle:"goal-b" user)

let () =
  init_prompt_config_for_tests ();
  init_runtime_default_for_tests ();
  run "keeper_wake_turn_context"
    [
      ( "current task layer",
        [
          test_case "renders id, status, and handoff" `Quick
            test_current_task_section_renders;
          test_case "absent without a held task" `Quick
            test_current_task_section_absent_without_task;
          test_case "held task skills section renders" `Quick
            test_held_task_skills_section_renders;
          test_case "held task skills section absent without held tasks" `Quick
            test_held_task_skills_section_absent_without_held_tasks;
          test_case "held task skills projection" `Quick
            test_held_task_skills_projection;
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
          test_case "direct turn carries held task skills" `Quick
            test_direct_turn_carries_held_task_skills;
          test_case "direct and autonomous turns share the stable contract"
            `Quick
            test_direct_and_autonomous_share_system_prompt;
          test_case "unresolved goal keeps one stable safety contract" `Quick
            test_open_goal_store_keeps_one_stable_safety_contract;
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
      ( "current task heading states the status",
        [
          test_case "a submitted task is not called held" `Quick
            test_submitted_task_heading_does_not_claim_a_hold;
          test_case "an in-progress task is still called held" `Quick
            test_in_progress_task_heading_still_says_held;
        ] );
      ( "own recent actions carry arguments on refusals",
        [
          test_case "a successful call replays no argument body" `Quick
            test_successful_call_arguments_are_not_replayed;
          test_case "a refused call keeps what was sent" `Quick
            test_refused_call_keeps_its_arguments;
          test_case "repeated refusals collapse into one digest row" `Quick
            test_failure_digest_dedupes_and_counts;
          test_case "no digest block without refusals" `Quick
            test_no_digest_without_failures;
        ] );
      ( "goal titles",
        [
          test_case "summaries render titles, unresolved ids stay bare" `Quick
            test_goal_summaries_render_titles;
          test_case "the heading counts what the block lists" `Quick
            test_goal_heading_counts_what_the_block_lists;
        ] );
    ]
