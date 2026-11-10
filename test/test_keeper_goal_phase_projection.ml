(** A keeper is handed every Goal the workspace can still progress.

    The turn's [### Active Goals] block renders the summaries
    ({!Keeper_unified_prompt.active_goal_summaries}): title, criterion and
    whether a task the keeper holds serves the goal. The turn observation
    records the same open goal ids in [world_observation.active_goals].
    [Goal_phase.admits_self_directed_progress] decides which goals are open on
    both surfaces. *)

open Alcotest
open Masc

let temp_dir () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "test_keeper_goal_phase_%d_%d" (Unix.getpid ())
         (Random.int 1_000_000))
  in
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  dir
;;

let with_workspace f =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  Fun.protect
    ~finally:(fun () -> Fs_compat.remove_tree dir)
    (fun () ->
      let config = Workspace.default_config dir in
      ignore (Workspace.init config ~agent_name:(Some "test"));
      f config)
;;

let goal_in phase id title =
  let ts = Masc_domain.now_iso () in
  { Goal_store.id
  ; criterion_revision = "fixture-" ^ id
  ; title
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; phase
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = ts
  ; updated_at = ts
  }
;;

(* One goal per phase, so a future phase added to [Goal_phase.t] shows up here
   as an unclassified id rather than silently inheriting a neighbour's verdict.
   [Verifying] (RFC-0387 stage 2) admits self-directed progress — the gate
   holds the phase, not the work — so it survives alongside Executing. *)
let seed_all_phases config =
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Executing "goal-executing" "still work"
        ; goal_in Goal_phase.Verifying "goal-verifying" "proof pending"
        ; goal_in Goal_phase.Completed "goal-completed" "already achieved"
        ; goal_in Goal_phase.Dropped "goal-dropped" "abandoned"
        ]
    }
;;

(* Only terminal Goals: nothing on the surface, and nothing that could be
   mistaken for an empty list produced some other way. *)
let seed_terminal_phases_only config =
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Completed "goal-completed" "already achieved"
        ; goal_in Goal_phase.Dropped "goal-dropped" "abandoned"
        ]
    }
;;

let keeper_name = "goal-phase-keeper"

let keeper_meta () =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [ "name", `String keeper_name
         ; "trace_id", `String "test-trace-goal-phase"
         ])
  with
  | Ok m -> m
  | Error e -> failwith ("meta_of_json failed: " ^ e)
;;

(* A held task, so a turn can carry independent work beside the Goal layer. *)
let task_named id : Masc_domain.task =
  { id
  ; title = "linked work"
  ; description = ""
  ; task_status = Masc_domain.Todo
  ; priority = 1
  ; files = []
  ; created_at = "2026-09-02T01:00:00Z"
  ; created_by = Some "test"
  ; predecessor_task_id = None
  ; contract = None
  ; execution_links = Masc_domain.no_execution_links
  ; handoff_context = None
  ; cycle_count = 0
  ; skills = []
  }
;;

let current_task_of id =
  Keeper_world_observation_inputs.Current_task (task_named id)
;;

let get_ok = function
  | Ok value -> value
  | Error unavailable -> fail (Goal_store.unavailable_to_string unavailable)
;;

let goal_store_unavailable : Goal_store.unavailable testable =
  testable
    (fun fmt unavailable ->
       Format.pp_print_string fmt (Goal_store.unavailable_to_string unavailable))
    ( = )
;;

let summary_ids summaries =
  let summaries = get_ok summaries in
  List.map
    (fun (s : Keeper_unified_prompt.goal_summary) -> s.summary_goal_id)
    summaries
;;

let summary_title_opt goal_id summaries =
  let summaries = get_ok summaries in
  match
    List.find_opt
      (fun (s : Keeper_unified_prompt.goal_summary) ->
        String.equal s.summary_goal_id goal_id)
      summaries
  with
  | Some s -> Some s.summary_title
  | None -> None
;;

let test_turn_surface_drops_terminal_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let summaries =
    Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name
  in
  check (list string) "only progressable goals are offered"
    [ "goal-executing"; "goal-verifying" ]
    (summary_ids summaries);
  check (option string) "its title still resolves" (Some "still work")
    (summary_title_opt "goal-executing" summaries)
;;

let contains_in haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  n = 0 || go 0
;;

let fragment key vars =
  match Prompt_registry.render_prompt_template key vars with
  | Ok text -> text
  | Error detail -> fail detail
;;

let goals_heading count =
  fragment Prompt_names.keeper_world_active_goals_heading
    [ "count", string_of_int count ]
;;

(* The text of the Goal Observations layer alone. Its rows start with the
   same "- <goal id>" as the Active Goals rows, so a row lookup reads only
   this layer. *)
let goal_observations_of partition =
  let observed, _ =
    Keeper_context_layers.partition_layer Keeper_context_layers.Goal_observations partition
  in
  Keeper_context_layers.text observed
;;

(* The Goal Observations row of [goal_id], found by its own template. The
   held-Task link marker lives here, not on the Active Goals row, because it
   changes on every claim and release and the Active Goals layer sits in the
   System prompt (docs/rfc/RFC-goal-observations-leave-the-system-prompt.md). *)
let observation_row observations ~goal_id =
  let row = fragment Prompt_names.keeper_world_goal_observations_row [ "goal_id", goal_id ] in
  match
    List.find_opt
      (fun line -> String.equal line row || String.starts_with ~prefix:(row ^ " ") line)
      (String.split_on_char '\n' observations)
  with
  | Some line -> line
  | None -> fail ("no Goal Observations row for " ^ goal_id)
;;

(* The rendered Active Goals row of [goal_id], found by its own template. *)
let goal_row world ~goal_id ~title =
  let row =
    fragment Prompt_names.keeper_world_active_goals_row
      [ "goal_id", goal_id; "title", title ]
  in
  match
    List.find_opt (String.starts_with ~prefix:row) (String.split_on_char '\n' world)
  with
  | Some line -> line
  | None -> fail ("no Active Goals row for " ^ goal_id)
;;

(* #45028. Every task the keeper holds marks the Goals its link names, whether
   or not it is the turn's current task, and nothing is removed. When the link
   registry cannot be read authoritatively the rows are marked unknown, not
   unlinked. *)
let test_held_tasks_mark_their_goals_without_hiding_others () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = keeper_meta () in
  let held =
    match
      Workspace.add_task_with_result config ~title:"held work" ~priority:2
        ~description:"linked to the verifying goal"
    with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace.add_task_error_to_string error)
  in
  (match Workspace.claim_task_r config ~agent_name:meta.name ~task_id:held () with
   | Ok _ -> ()
   | Error _ -> fail "the keeper could not claim its task");
  Workspace_goal_index.write_goal_task_links config [ "goal-verifying", [ held ] ];
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
  in
  let world ~keeper_name =
    let { Keeper_unified_prompt.world_state; world_partition; _ } =
      Keeper_unified_prompt.build_prompt
        ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
        ~current_task:Keeper_world_observation_inputs.No_current_task
        ~active_goal_summaries:
          (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name)
        ~observation ()
    in
    world_state, goal_observations_of world_partition
  in
  let yours = fragment Prompt_names.keeper_world_active_goals_yours_annotation [] in
  let unknown =
    fragment Prompt_names.keeper_world_active_goals_held_task_link_unreadable_annotation []
  in
  let marked, marked_observations = world ~keeper_name:meta.name in
  check bool "a held task that is not the current task marks its goal" true
    (contains_in (observation_row marked_observations ~goal_id:"goal-verifying") yours);
  check bool "the Active Goals row carries no held-Task marker" false
    (contains_in (goal_row marked ~goal_id:"goal-verifying" ~title:"proof pending") yours);
  check bool "the other open goal stays listed, unmarked" false
    (contains_in (observation_row marked_observations ~goal_id:"goal-executing") yours);
  check bool "both open goals are counted" true (contains_in marked (goals_heading 2));
  let other_keeper, _ = world ~keeper_name:"keeper-holding-nothing" in
  check bool "a keeper holding nothing marks nothing" false (contains_in other_keeper yours);
  check bool "and sees the same goals" true (contains_in other_keeper (goals_heading 2));
  Fs_compat.save_file (Workspace_goal_index.goal_task_links_path config) "unreadable";
  let unreadable, unreadable_observations = world ~keeper_name:meta.name in
  check bool "a recovery copy does not stand in for the registry" false
    (contains_in unreadable yours);
  check bool "every open goal is marked unknown" true
    (contains_in (observation_row unreadable_observations ~goal_id:"goal-executing") unknown
     && contains_in (observation_row unreadable_observations ~goal_id:"goal-verifying") unknown);
  check bool "a keeper holding nothing needs no links" false
    (contains_in (fst (world ~keeper_name:"keeper-holding-nothing")) unknown)
;;

let test_world_observation_drops_terminal_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let meta = keeper_meta () in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config
      ~meta
  in
  check (list string) "the per-turn frame agrees with the system prompt"
    [ "goal-executing"; "goal-verifying" ]
    (get_ok observation.Keeper_world_observation.active_goals)
;;

(* Terminal phases are the only thing that removes a Goal from the surface.
   Seed a store whose Goals are all terminal and neither surface offers any --
   an empty block rather than one that looks empty for a different reason. *)
let test_no_goals_surface_when_all_are_terminal () =
  with_workspace @@ fun config ->
  seed_terminal_phases_only config;
  let meta = keeper_meta () in
  check (list string) "no goal block rather than an empty-looking one" []
    (summary_ids
       (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name));
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config
      ~meta
  in
  check (list string) "and the frame carries none either" []
    (get_ok observation.Keeper_world_observation.active_goals)
;;

(* A Goal is a standing question, not an assignment. Nothing in a turn frame
   invites a Keeper to pick one up. *)
let rendered_world_state config =
  let meta = keeper_meta () in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
  in
  let { Keeper_unified_prompt.world_state; _ } =
    Keeper_unified_prompt.build_prompt
      ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~active_goal_summaries:(Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name)
      ~observation
      ()
  in
  world_state
;;

let test_no_goal_is_offered_as_work_to_pick_up () =
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ goal_in Goal_phase.Executing "goal-open" "nobody started this"
        ; goal_in Goal_phase.Completed "goal-done" "already achieved"
        ]
    };
  let world = rendered_world_state config in
  check bool "the open goal is in the frame" true (contains_in world (goals_heading 1));
  check bool "no heading invites the keeper to start work on a goal" false
    (contains_in world "no Task yet");
  check bool "no goal is named as a move to make" false
    (contains_in world "picking one up")
;;

let test_unreadable_goals_preserve_context_and_independent_turn () =
  with_workspace @@ fun config ->
  let runtime_snapshot = Runtime.For_testing.snapshot () in
  Fun.protect ~finally:(fun () -> Runtime.For_testing.restore runtime_snapshot) @@ fun () ->
  let runtime_path = Filename.concat config.base_path "runtime.toml" in
  Fs_compat.save_file runtime_path {|
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
|};
  (match Runtime.init_default ~config_path:runtime_path with
   | Ok () -> () | Error detail -> fail detail);
  seed_all_phases config;
  let goal = { (goal_in Goal_phase.Executing "goal-executing" "Publish an audio essay") with
    metric = Some "independently reviewed playable audio essays";
    target_value = Some "1";
    last_review_note = Some "Audio has not yet been played back." } in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = Masc_domain.now_iso (); goals = [goal] };
  let meta = keeper_meta () in
  let check_criterion expected_metric expected_target expected_review absent_text () =
    let observation = Keeper_world_observation.observe
      ~pending_board_events:(Some []) ~config ~meta in
    let summaries = Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name in
    (* No task is held and no task links this Goal: the criterion reaches the
       turn anyway, because a Goal is shared and not reached through a task. *)
    let { Keeper_unified_prompt.world_state; _ } = Keeper_unified_prompt.build_prompt
      ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~active_goal_summaries:summaries ~observation () in
    check bool "stored criterion reaches the actual turn context" true
      (contains_in world_state expected_metric);
    check bool "target reaches the actual turn context" true
      (contains_in world_state expected_target);
    check bool "stale values do not remain in the turn context" false
      (contains_in world_state absent_text);
    check bool "review evidence reaches the actual turn context" true
      (contains_in world_state expected_review);
    check bool "criterion identity is available for evidence binding" true
      (contains_in world_state goal.criterion_revision)
  in
  check_criterion "independently reviewed playable audio essays"
    "\"target_value\":\"1\"" "Audio has not yet been played back."
    "Provide an explicit measurable criterion." ();
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1; updated_at = Masc_domain.now_iso ();
      goals = [{ goal with metric = None; target_value = None;
        last_review_note = Some "Provide an explicit measurable criterion." }] };
  check_criterion "\"metric\":null" "\"target_value\":null"
    "Provide an explicit measurable criterion."
    "independently reviewed playable audio essays" ();
  let primary = Goal_store.goals_path config in
  let mirror = primary ^ ".last-good" in
  let original = Fs_compat.load_file primary in
  let meta = keeper_meta () in
  let check_unavailable () =
    let observation = Keeper_world_observation.observe
      ~pending_board_events:(Some []) ~config ~meta in
    let unavailable = match observation.active_goals with
      | Error unavailable -> unavailable
      | Ok _ -> fail "an unreadable Goal source became an available list" in
    check string "read failure names the file it could not read" primary
      unavailable.Goal_store.file;
    let summaries = Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name in
    (match summaries with
     | Error _ -> () | Ok _ -> fail "the summaries lost the Goal read failure");
    let observation = { observation with pending_messages =
      [ { Keeper_world_observation_message_scope.message_id = "independent-message"
        ; speaker = "operator"; content = "Please inspect the independent file."
        ; kind = Keeper_world_observation_message_scope.Mention } ] } in
    let decision = Keeper_world_observation.keeper_cycle_decision ~meta observation in
    check bool "independent mention still admits a turn" true decision.should_run;
    let { Keeper_unified_prompt.world_state; _ } = Keeper_unified_prompt.build_prompt ~turn_decision:decision
      ~current_task:(current_task_of "task-linked")
      ~active_goal_summaries:summaries ~observation () in
    check bool "Goal failure reaches the model context" true
      (contains_in world_state "goal_store_unavailable");
    check bool "independent request stays visible" true
      (contains_in world_state "Please inspect the independent file.");
    let log_path = Keeper_types_support.keeper_decision_log_path config meta.name in
    let directory = Filename.dirname log_path in
    if not (Sys.file_exists directory) then Unix.mkdir directory 0o755;
    Keeper_unified_metrics_decision.append_decision_record ~config ~meta
      ~turn_ctx_cell:(Keeper_tool_call_log.create_turn_ctx_cell ())
      ~observation ~latency_ms:0 ~outcome:Keeper_decision_outcome.Success
      ~execution_path:Keeper_unified_metrics_decision.Autonomous_cycle
      ~degraded_retry_applied:None ~degraded_retry_deferred:None ();
    let rows = Fs_compat.load_file log_path |> String.split_on_char '\n'
      |> List.filter (fun row -> row <> "") in
    let row = List.rev rows |> List.hd |> Yojson.Safe.from_string in
    let open Yojson.Safe.Util in
    let observed = member "observation" row in
    check bool "frame does not invent a zero count" true
      (member "active_goals" observed = `Null);
    check string "frame retains the unavailable source" "unavailable"
      (observed |> member "active_goals_source" |> member "status" |> to_string)
  in
  Fs_compat.save_file primary "unreadable-primary";
  check_unavailable ();
  check string "observing does not repair primary" "unreadable-primary"
    (Fs_compat.load_file primary);
  check string "observing leaves the recovery copy unchanged" original
    (Fs_compat.load_file mirror);
  Sys.remove primary;
  check_unavailable ();
  check bool "missing primary is not recreated" false (Sys.file_exists primary);
  Sys.remove mirror;
  let fresh = Keeper_world_observation.observe
    ~pending_board_events:(Some []) ~config ~meta in
  check (result (list string) goal_store_unavailable) "fresh store is genuinely empty"
    (Ok []) fresh.active_goals
;;

(* RFC-0444 §2.3 row 6. The 2026-09-08 shape: every row lacks
   [criterion_revision], the mirror still decodes. The Active Goals layer must
   say which member the decoder refused and which file, and must not draw a
   Goal count or heading, because a store that cannot be read holds an
   unknown number of Goals, not zero. *)
let test_schema_rejected_store_renders_reason_and_file_not_zero_goals () =
  with_workspace @@ fun config ->
  seed_all_phases config;
  let primary = Goal_store.goals_path config in
  let stripped =
    match Yojson.Safe.from_string (Fs_compat.load_file primary) with
    | `Assoc members ->
      `Assoc
        (List.map
           (function
             | "goals", `List goals ->
               ( "goals"
               , `List
                   (List.map
                      (function
                        | `Assoc goal ->
                          `Assoc
                            (List.filter
                               (fun (key, _) -> not (String.equal key "criterion_revision"))
                               goal)
                        | other -> other)
                      goals) )
             | member -> member)
           members)
    | _ -> fail "goals.json is not an object"
  in
  Fs_compat.save_file primary (Yojson.Safe.to_string stripped);
  let meta = keeper_meta () in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
  in
  (match observation.active_goals with
   | Error { Goal_store.reason = Goal_store.Schema_rejected { field; _ }; file; _ } ->
     check string "the refused member is named" "criterion_revision" field;
     check string "the file is named" primary file
   | Error _ -> fail "the reason is not the refused schema member"
   | Ok _ -> fail "rows without criterion_revision read as a Goal list");
  let world = rendered_world_state config in
  check bool "the layer names the refused member" true
    (contains_in world "schema_rejected location=\"criterion_revision\"");
  check bool "the layer names the file" true (contains_in world primary);
  check bool "the layer says the source is unavailable" true
    (contains_in world "Active Goals — source unavailable");
  check bool "no Goal count is drawn" false (contains_in world "Active Goals (0)");
  check bool "no Goal heading is drawn" false (contains_in world "### Active Goals (")
;;

let test_goal_measurement_tracks_current_revision_and_read_failure () =
  with_workspace @@ fun config ->
  let goal_id = "goal-executing" in
  let declared_goal =
    { (goal_in Goal_phase.Executing goal_id "acceptance outcome") with
      metric = Some "observed acceptance cases"
    ; target_value = Some "2 of 2 cases observed with evidence"
    }
  in
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso (); goals = [ declared_goal ]
    };
  let summary () =
    match
      List.find_opt
        (fun (value : Keeper_unified_prompt.goal_summary) ->
           String.equal value.summary_goal_id goal_id)
        (get_ok (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name))
    with
    | Some value -> value
    | None -> fail "the open Goal disappeared"
  in
  (match (summary ()).summary_measurement with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "an unmeasured Goal needs an explicit empty observation");
  check bool "world state exposes missing measurement" true
    (contains_in (rendered_world_state config)
       "Current criterion has no recorded measurement");
  let goal =
    match Goal_store.find_goal config ~goal_id with
    | Goal_store.Goal_found goal -> goal
    | Goal_store.Goal_absent | Goal_store.Store_unavailable _ -> fail "fixture Goal unavailable"
  in
  (match Goal_measurement.record config ~goal_id
           ~criterion_revision:goal.criterion_revision
           ~observed_value:"0 of 2 acceptance cases observed"
           ~evidence:"note:baseline execution, neither required result observed"
           ~actor:keeper_name with
   | Ok _ -> ()
   | Error error -> fail (Goal_measurement.error_to_string error));
  (match (summary ()).summary_measurement with
   | Ok (Some measured) ->
     check string "observed zero is preserved" "0 of 2 acceptance cases observed"
       measured.observed_value;
     check string "evidence identity is preserved"
       "note:baseline execution, neither required result observed" measured.evidence;
     check string "measurement names the admitted criterion" goal.criterion_revision
       measured.criterion_revision
   | Ok None | Error _ -> fail "the recorded measurement did not reach turn context");
  let measured_world = rendered_world_state config in
  check bool "world state carries the measured zero" true
    (contains_in measured_world "0 of 2 acceptance cases observed");
  check bool "world state carries its submitted evidence" true
    (contains_in measured_world
       "note:baseline execution, neither required result observed");
  check bool "world state labels observation separately from verified completion" true
    (contains_in measured_world "not verified completion or an instruction");
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals = [ { goal with criterion_revision = "changed-criterion" } ]
    };
  (match (summary ()).summary_measurement with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "a previous criterion's measurement leaked into the new one");
  let changed_world = rendered_world_state config in
  check bool "world state omits the old criterion's measured value" false
    (contains_in changed_world "0 of 2 acceptance cases observed");
  check bool "world state exposes the new criterion as unmeasured" true
    (contains_in changed_world "Current criterion has no recorded measurement");
  Fs_compat.save_file (Goal_measurement.path config) "not JSON";
  (match (summary ()).summary_measurement with
   | Error _ -> ()
   | Ok None | Ok (Some _) -> fail "an unreadable measurement was converted to a value");
  let unavailable_world = rendered_world_state config in
  check bool "world state preserves the open Goal when measurement is unreadable" true
    (contains_in unavailable_world goal_id);
  check bool "world state reports the unavailable source" true
    (contains_in unavailable_world "Measurement source unavailable");
  check bool "world state preserves unknown measurement semantics" true
    (contains_in unavailable_world "Its value is unknown; preserve the Goal")
;;

(* RFC-goal-observations-leave-the-system-prompt. The Active Goals layer becomes
   the System suffix that precedes the history, so a recorded measurement or a
   claimed linked Task must leave its bytes as they were; only the Goal
   Observations layer, which rides the trailing context, moves. *)
let test_a_measurement_or_a_claim_moves_only_the_goal_observations () =
  with_workspace @@ fun config ->
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso ()
    ; goals =
        [ { (goal_in Goal_phase.Executing "goal-executing" "still work") with
            metric = Some "observed fixture cases"
          ; target_value = Some "3 of 3 fixture cases observed"
          }
        ; goal_in Goal_phase.Verifying "goal-verifying" "proof pending"
        ]
    };
  let meta = keeper_meta () in
  let layers () =
    let observation =
      Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
    in
    let { Keeper_unified_prompt.world_partition; _ } =
      Keeper_unified_prompt.build_prompt
        ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
        ~current_task:Keeper_world_observation_inputs.No_current_task
        ~active_goal_summaries:
          (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name:meta.name)
        ~observation ()
    in
    let goals, rest =
      Keeper_context_layers.partition_layer Keeper_context_layers.Active_goals world_partition
    in
    Keeper_context_layers.text goals, goal_observations_of rest
  in
  let goals_before, observed_before = layers () in
  check bool "the observations name every open Goal" true
    (contains_in observed_before "goal-executing" && contains_in observed_before "goal-verifying");
  let goal =
    match Goal_store.find_goal config ~goal_id:"goal-executing" with
    | Goal_store.Goal_found goal -> goal
    | Goal_store.Goal_absent | Goal_store.Store_unavailable _ -> fail "fixture Goal unavailable"
  in
  (match Goal_measurement.record config ~goal_id:goal.id
           ~criterion_revision:goal.criterion_revision
           ~observed_value:"1 of 3 fixture cases observed"
           ~evidence:"note:fixture measurement" ~actor:meta.name with
   | Ok _ -> ()
   | Error error -> fail (Goal_measurement.error_to_string error));
  let goals_measured, observed_measured = layers () in
  check string "a recorded measurement leaves the Active Goals bytes" goals_before goals_measured;
  check bool "the measurement reaches the observations" true
    (contains_in observed_measured "1 of 3 fixture cases observed");
  check bool "the Active Goals layer carries no measurement" false
    (contains_in goals_measured "1 of 3 fixture cases observed");
  let held =
    match
      Workspace.add_task_with_result config ~title:"held work" ~priority:2
        ~description:"linked to the executing goal"
    with
    | Ok created -> created.task_id
    | Error error -> fail (Workspace.add_task_error_to_string error)
  in
  (match Workspace.claim_task_r config ~agent_name:meta.name ~task_id:held () with
   | Ok _ -> ()
   | Error _ -> fail "the keeper could not claim its task");
  Workspace_goal_index.write_goal_task_links config [ "goal-executing", [ held ] ];
  let goals_claimed, observed_claimed = layers () in
  check string "a claimed linked Task leaves the Active Goals bytes" goals_before goals_claimed;
  check bool "the claim reaches the observations" false
    (String.equal observed_measured observed_claimed)
;;

(* Agent Core carries the current proof state in System so every tool round
   sees it without an extra User message. The Active Goals list keeps its
   stable order, while a new turn observes any proof-state change. *)
let system_of_text text =
  match
    Keeper_turn_system.issue ~held:None ~lane:Keeper_turn_system.Without_basis
      ~render:(fun (_ : World_constitution_types.t list) -> text) ~current:[]
      ~at:{ World_constitution_store.end_offset = 0; digest = "" }
      ~articles_at:(fun (_ : World_constitution_store.position) -> Ok None)
  with
  | Ok (system, (_ : Keeper_turn_system.held)) -> system
  | Error () -> fail "a turn without a basis reads no ledger"
;;

let goal_at phase ~priority ~created_at ~updated_at id =
  { (goal_in phase id ("title of " ^ id)) with priority; created_at; updated_at }
;;

let write_goals config goals =
  Goal_store.write_state config
    { pending_events = []; pending_notifications = []; version = 1
    ; updated_at = Masc_domain.now_iso (); goals }
;;

(* The first request of a turn as request assembly issues it, and the world
   state it was assembled from. *)
let first_request config =
  let meta = keeper_meta () in
  let observation =
    Keeper_world_observation.observe ~pending_board_events:(Some []) ~config ~meta
  in
  let { Keeper_unified_prompt.world_state; world_partition; _ } =
    Keeper_unified_prompt.build_prompt
      ~turn_decision:(Keeper_world_observation.keeper_cycle_decision ~meta observation)
      ~current_task:Keeper_world_observation_inputs.No_current_task
      ~active_goal_summaries:
        (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name:meta.name)
      ~observation ()
  in
  ( Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Masc_agent_core ~system:(system_of_text "BASE")
      ~post_tool_round:false ~previous_assembly:None
      ~dynamic_context_partition:(Some world_partition) ~existing_extra_system_context:None
      ~blocks:[ Prompt_block_id.Dynamic_context, world_state ]
  , world_partition )
;;

let issued_system (assembly : Keeper_context_assembly.t) =
  match assembly.system_prompt with
  | Some issued -> issued.text
  | None -> fail "the request issues no System"
;;

let awaiting_blocks (assembly : Keeper_context_assembly.t) =
  List.filter_map
    (fun (id, text) ->
       if Prompt_block_id.equal id Prompt_block_id.Goals_awaiting_proof then Some text else None)
    (Keeper_context_assembly.logical_blocks assembly)
;;

let awaiting_row goal_id =
  fragment Prompt_names.keeper_world_goals_awaiting_proof_row [ "goal_id", goal_id ]
;;

let test_a_goal_under_proof_is_current_system_state () =
  with_workspace @@ fun config ->
  let at hour = Printf.sprintf "2026-11-06T%02d:00:00Z" hour in
  let goal phase ~updated = goal_at phase ~priority:3 ~created_at:(at 1) ~updated_at:(at updated) in
  let store_order () =
    summary_ids (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name) in
  write_goals config
    [ goal Goal_phase.Executing ~updated:3 "goal-a"; goal Goal_phase.Executing ~updated:2 "goal-b" ];
  let executing, _ = first_request config in
  check (list string) "the store lists the newer update first" [ "goal-a"; "goal-b" ] (store_order ());
  check (list string) "no Goal under proof, no block" [] (awaiting_blocks executing);
  (* A completion request moves goal-b to Verifying and writes its
     [updated_at], which puts it first in the store's order. *)
  write_goals config
    [ goal Goal_phase.Executing ~updated:3 "goal-a"; goal Goal_phase.Verifying ~updated:4 "goal-b" ];
  check (list string) "the completion request reorders the store" [ "goal-b"; "goal-a" ]
    (store_order ());
  let verifying, _ = first_request config in
  check bool "entering Verifying changes current System state" false
    (String.equal (issued_system executing) (issued_system verifying));
  let row = fragment Prompt_names.keeper_world_active_goals_row
      [ "goal_id", "goal-b"; "title", "title of goal-b" ] in
  check bool "the System row of the Goal under proof is the plain row" true
    (List.mem row (String.split_on_char '\n' (issued_system verifying)));
  check bool "the System carries the current proof-pending mark" true
    (contains_in (issued_system verifying) (awaiting_row "goal-b"));
  (match awaiting_blocks verifying with
   | [ block ] ->
     check bool "the block names the Goal under proof with its mark" true
       (contains_in block (awaiting_row "goal-b"));
     check bool "and no other Goal" false (contains_in block "goal-a")
   | blocks -> failf "one Goals_awaiting_proof block expected, got %d" (List.length blocks));
  check bool "the proof mark is absent from the User context" false
    (match verifying.extra_system_context with
     | Some carrier -> contains_in carrier (awaiting_row "goal-b")
     | None -> false);
  let later =
    Keeper_run_prompt.assemble_request_context ~checkpoint_owner:Runtime_execution.Masc_agent_core ~system:(system_of_text "BASE")
      ~post_tool_round:true ~previous_assembly:(Some verifying) ~dynamic_context_partition:None
      ~existing_extra_system_context:None ~blocks:[]
  in
  check (list string) "a later round of the turn carries the same block"
    (awaiting_blocks verifying) (awaiting_blocks later);
  check string "tool rounds retain the exact same System"
    (issued_system verifying) (issued_system later);
  check (option string) "proof state creates no post-tool User carrier" None later.extra_system_context;
  (* The verifier refutes the proof: goal-b is back in Executing and its
     [updated_at] moved again. *)
  write_goals config
    [ goal Goal_phase.Executing ~updated:3 "goal-a"; goal Goal_phase.Executing ~updated:5 "goal-b" ];
  let refuted, _ = first_request config in
  check string "a refuted proof restores the executing System" (issued_system executing)
    (issued_system refuted);
  check (list string) "and the block leaves" [] (awaiting_blocks refuted)
;;

let test_proof_state_follows_the_runtime_execution_owner () =
  let operation = "kmsg-eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" in
  let peer = "proof-source-peer" in
  let operation_id = match Keeper_chat_operation.Operation_id.of_string operation with
    | Ok id -> id | Error detail -> fail detail in
  let keeper_id = match Keeper_identity.Keeper_id.of_string peer with
    | Some id -> id | None -> fail "fixture peer must have a canonical Keeper identity" in
  let source = Keeper_direct_input_source.of_admitted_input ~operation_id
      ~speaker:(Keeper_input_speaker.Person (Keeper_input_speaker.Keeper keeper_id))
      |> Keeper_direct_input_source.render in
  List.iter (fun identity -> check bool "the admitted source names its original operation and peer"
    true (contains_in source identity)) [operation; peer];
  let partition = Keeper_context_layers.assemble ~content_of:(function
    | Keeper_context_layers.Goals_awaiting_proof -> Some "CURRENT_PROOF_STATE"
    | Keeper_context_layers.Active_goals -> Some "CURRENT_GOAL"
    | Keeper_context_layers.Direct_input_source -> Some source
    | Keeper_context_layers.Goal_observations | Current_task | Approval_authority
    | Connected_surfaces | Namespace_state | Workspace_memory | Wiki | Lane_updates
    | Autonomous_trigger | Scheduled_automation | Completion_authority | Task_cancellations
    | Pending_mentions | Scope_messages | Own_board_posts | Board_activity
    | Own_recent_actions | Recent_work | Fleet_messages -> None) in
  let assemble checkpoint_owner post_tool_round previous_assembly blocks =
    Keeper_run_prompt.assemble_request_context ~checkpoint_owner
      ~system:(system_of_text "BASE") ~post_tool_round ~previous_assembly
      ~dynamic_context_partition:(Some partition) ~existing_extra_system_context:None ~blocks in
  let check_source (assembly : Keeper_context_assembly.t) =
    let sources = match assembly.system_prompt with
      | None -> fail "the admitted source requires an issued System"
      | Some issued -> List.filter_map (function
          | Keeper_context_assembly.Direct_input_source text -> Some text
          | Active_goals _ | Goals_awaiting_proof _ -> None) issued.observations in
    check (list string) "the exact admitted source stays in System once" [source] sources;
    check bool "the actual issued System retains the exact source bytes" true
      (contains_in (issued_system assembly) source);
    check bool "the source acquires no User context block" false
      (List.mem_assoc Prompt_block_id.Direct_input_source assembly.blocks);
    List.iter (fun identity ->
      check bool "the original operation and peer are not replayed in a User carrier" false
        (match assembly.extra_system_context with
         | Some carrier -> contains_in carrier identity
         | None -> false)) [operation; peer] in
  List.iter (fun extra_blocks ->
    let first = assemble Runtime_execution.Masc_agent_core false None
        ((Prompt_block_id.Dynamic_context, Keeper_context_layers.text partition) :: extra_blocks) in
    check_source first;
    check bool "only renderer-issued proof enters System" false
      (contains_in (issued_system first) "UNISSUED_PROOF");
    let official = assemble Runtime_execution.Official_client true (Some first) [] in
    check_source official;
    check bool "official System retains no turn-scoped proof state" false
      (contains_in (issued_system official) "CURRENT_PROOF_STATE");
    check (list string) "official fallback receives only the renderer-issued proof state"
      ["CURRENT_PROOF_STATE"] (awaiting_blocks official);
    check (list (pair string string)) "only proof moves to the official User carrier"
      ["goals_awaiting_proof", "CURRENT_PROOF_STATE"]
      (List.map (fun (id, text) -> Prompt_block_id.to_string id, text) official.blocks);
    let core = assemble Runtime_execution.Masc_agent_core true (Some official) [] in
    check_source core;
    check string "Agent Core fallback restores the same System"
      (issued_system first) (issued_system core);
    check (option string) "Agent Core fallback leaves no proof User carrier" None core.extra_system_context)
    [ []; [Prompt_block_id.Goals_awaiting_proof, "UNISSUED_PROOF"] ]
;;

let test_unattributed_proof_text_is_not_system_authority () =
  let partition = Keeper_context_layers.assemble ~content_of:(function
    | Keeper_context_layers.Goals_awaiting_proof -> Some "RENDERED_PROOF"
    | _ -> None) in
  let raw = Prompt_block_id.Goals_awaiting_proof, "UNISSUED_PROOF" in
  let cases =
    [ false, None, [raw]
    ; false, Some partition, [Prompt_block_id.Dynamic_context, "STALE_RENDER"; raw]
    ; true, None, [raw] ] in
  List.iter (fun (post_tool_round, dynamic_context_partition, blocks) ->
    let assembly = Keeper_run_prompt.assemble_request_context
        ~checkpoint_owner:Runtime_execution.Masc_agent_core
        ~system:(system_of_text "BASE") ~post_tool_round ~previous_assembly:None
        ~dynamic_context_partition ~existing_extra_system_context:None ~blocks in
    let check_unissued assembly =
      check string "unattributed text acquires no System authority" "BASE"
        (issued_system assembly);
      check bool "no renderer-issued proof is inferred from raw blocks" true
        (Option.is_none assembly.Keeper_context_assembly.proof_state) in
    check_unissued assembly;
    ignore (List.fold_left (fun previous checkpoint_owner ->
      let later = Keeper_run_prompt.assemble_request_context ~checkpoint_owner
          ~system:(system_of_text "BASE") ~post_tool_round:true ~previous_assembly:(Some previous)
          ~dynamic_context_partition:None ~existing_extra_system_context:None ~blocks:[] in
      check_unissued later;
      later) assembly
      [Runtime_execution.Masc_agent_core; Runtime_execution.Official_client;
       Runtime_execution.Masc_agent_core])) cases
;;

let test_the_system_orders_goals_by_priority_created_at_and_id () =
  with_workspace @@ fun config ->
  let at hour = Printf.sprintf "2026-11-06T%02d:00:00Z" hour in
  write_goals config
    [ goal_at Goal_phase.Executing ~priority:3 ~created_at:(at 1) ~updated_at:(at 9) "goal-d"
    ; goal_at Goal_phase.Executing ~priority:3 ~created_at:(at 2) ~updated_at:(at 5) "goal-a"
    ; goal_at Goal_phase.Executing ~priority:3 ~created_at:(at 1) ~updated_at:(at 3) "goal-b"
    ; goal_at Goal_phase.Executing ~priority:1 ~created_at:(at 3) ~updated_at:(at 1) "goal-c"
    ];
  let assembly, world_partition = first_request config in
  let system = issued_system assembly in
  let position goal_id =
    let row = fragment Prompt_names.keeper_world_active_goals_row
        [ "goal_id", goal_id; "title", "title of " ^ goal_id ] in
    match
      List.find_index (String.equal row) (String.split_on_char '\n' system)
    with
    | Some index -> index
    | None -> fail ("no System row for " ^ goal_id)
  in
  check (list string) "priority, then created_at, then id"
    [ "goal-c"; "goal-b"; "goal-d"; "goal-a" ]
    (List.sort (fun left right -> Int.compare (position left) (position right))
       [ "goal-a"; "goal-b"; "goal-c"; "goal-d" ]);
  check (list string) "the summaries keep the store's (priority, updated_at) order"
    [ "goal-c"; "goal-d"; "goal-a"; "goal-b" ]
    (summary_ids (Keeper_unified_prompt.active_goal_summaries ~config ~keeper_name));
  let observations = goal_observations_of world_partition in
  let observation_position goal_id =
    let row = fragment Prompt_names.keeper_world_goal_observations_row [ "goal_id", goal_id ] in
    match
      List.find_index (String.starts_with ~prefix:row) (String.split_on_char '\n' observations)
    with
    | Some index -> index
    | None -> fail ("no Goal Observations row for " ^ goal_id)
  in
  check (list string) "the Goal Observations rows keep the store's order"
    [ "goal-c"; "goal-d"; "goal-a"; "goal-b" ]
    (List.sort (fun left right ->
         Int.compare (observation_position left) (observation_position right))
       [ "goal-a"; "goal-b"; "goal-c"; "goal-d" ])
;;

let () =
  run "keeper_goal_phase_projection"
    [ ( "prompt surfaces"
      , [ test_case "Goal measurement preserves current revision and unavailable source" `Quick
            test_goal_measurement_tracks_current_revision_and_read_failure
        ; test_case "schema-rejected rows render reason and file, never zero goals" `Quick
            test_schema_rejected_store_renders_reason_and_file_not_zero_goals
        ; test_case "unavailable Goal source preserves independent turn and frame" `Quick
            test_unreadable_goals_preserve_context_and_independent_turn
        ; test_case "the turn surface drops terminal goals" `Quick
            test_turn_surface_drops_terminal_goals
        ; test_case "held tasks mark their goals without hiding others" `Quick
            test_held_tasks_mark_their_goals_without_hiding_others
        ; test_case "a measurement or a claim moves only the Goal observations" `Quick
            test_a_measurement_or_a_claim_moves_only_the_goal_observations
        ; test_case "a Goal under proof is current System state without a User replay" `Quick
            test_a_goal_under_proof_is_current_system_state
        ; test_case "proof state follows an execution-owner fallback" `Quick
            test_proof_state_follows_the_runtime_execution_owner
        ; test_case "unattributed proof text acquires no System authority" `Quick
            test_unattributed_proof_text_is_not_system_authority
        ; test_case "the System orders Goals by priority, created_at and id" `Quick
            test_the_system_orders_goals_by_priority_created_at_and_id
        ; test_case "world observation drops terminal goals" `Quick
            test_world_observation_drops_terminal_goals
        ; test_case "all-terminal yields no goals at either surface" `Quick
            test_no_goals_surface_when_all_are_terminal
        ] )
    ; ( "goals are not assignments"
      , [ test_case "no goal is offered as work to pick up" `Quick
            test_no_goal_is_offered_as_work_to_pick_up
        ] )
    ]
;;
