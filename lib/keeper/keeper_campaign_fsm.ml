(** Keeper_campaign_fsm — pure campaign goal-reaching sub-FSM.

    This FSM is orthogonal to {!Keeper_state_machine}. It models the keeper
    campaign harness mission contract only: goal bootstrap, task binding,
    autoresearch progress, lifecycle pressure, and continuity verification. *)

type phase =
  | Bootstrapping
  | Claiming_task
  | Task_bound
  | Searching
  | Target_reached
  | Pressure_testing
  | Continuity_verified
  | Stalled
  | Escalated

type snapshot = {
  phase : phase;
  goal : string option;
  task_id : string option;
  current_task_id : string option;
  loop_id : string option;
  target_score : float option;
  target_reached : bool;
  compaction_count : int;
  handoff_count : int;
  continuity_goal_matches : bool option;
  continuity_task_matches : bool option;
  reason : string option;
}

type event =
  | Bootstrap_ok of { goal : string }
  | Task_bound_observed of { task_id : string; current_task_id : string }
  | Autoresearch_started of {
      loop_id : string;
      target_score : float option;
    }
  | Target_reached_event
  | Pressure_started
  | Compaction_observed of { count : int }
  | Handoff_observed of {
      count : int;
      generation : int option;
      trace_id : string option;
    }
  | Continuity_observed of {
      goal_matches : bool;
      current_task_id : string option;
    }
  | Window_exhausted of { reason : string }
  | Error_observed of { reason : string }

let initial =
  {
    phase = Bootstrapping;
    goal = None;
    task_id = None;
    current_task_id = None;
    loop_id = None;
    target_score = None;
    target_reached = false;
    compaction_count = 0;
    handoff_count = 0;
    continuity_goal_matches = None;
    continuity_task_matches = None;
    reason = None;
  }

let phase_to_string = function
  | Bootstrapping -> "bootstrapping"
  | Claiming_task -> "claiming_task"
  | Task_bound -> "task_bound"
  | Searching -> "searching"
  | Target_reached -> "target_reached"
  | Pressure_testing -> "pressure_testing"
  | Continuity_verified -> "continuity_verified"
  | Stalled -> "stalled"
  | Escalated -> "escalated"

let phase_of_string = function
  | "bootstrapping" -> Some Bootstrapping
  | "claiming_task" -> Some Claiming_task
  | "task_bound" -> Some Task_bound
  | "searching" -> Some Searching
  | "target_reached" -> Some Target_reached
  | "pressure_testing" -> Some Pressure_testing
  | "continuity_verified" -> Some Continuity_verified
  | "stalled" -> Some Stalled
  | "escalated" -> Some Escalated
  | _ -> None

let phase_terminal = function
  | Continuity_verified | Stalled | Escalated -> true
  | Bootstrapping | Claiming_task | Task_bound | Searching
  | Target_reached | Pressure_testing -> false

let verdict_of_phase = function
  | Continuity_verified -> Some "reached"
  | Stalled -> Some "stalled"
  | Escalated -> Some "escalated"
  | Bootstrapping | Claiming_task | Task_bound | Searching
  | Target_reached | Pressure_testing -> None

let event_to_string = function
  | Bootstrap_ok _ -> "bootstrap_ok"
  | Task_bound_observed _ -> "task_bound_observed"
  | Autoresearch_started _ -> "autoresearch_started"
  | Target_reached_event -> "target_reached"
  | Pressure_started -> "pressure_started"
  | Compaction_observed _ -> "compaction_observed"
  | Handoff_observed _ -> "handoff_observed"
  | Continuity_observed _ -> "continuity_observed"
  | Window_exhausted _ -> "window_exhausted"
  | Error_observed _ -> "error_observed"

let ( let* ) = Result.bind

let continuity_task_matches snapshot current_task_id =
  match snapshot.task_id, current_task_id with
  | Some task_id, Some current_task_id -> String.equal task_id current_task_id
  | _ -> false

let json_of_option f = function
  | Some value -> f value
  | None -> `Null

let snapshot_to_yojson snapshot =
  let fields =
    [
      ("phase", `String (phase_to_string snapshot.phase));
      ("goal", json_of_option (fun x -> `String x) snapshot.goal);
      ("task_id", json_of_option (fun x -> `String x) snapshot.task_id);
      ("current_task_id", json_of_option (fun x -> `String x) snapshot.current_task_id);
      ("loop_id", json_of_option (fun x -> `String x) snapshot.loop_id);
      ("target_score", json_of_option (fun x -> `Float x) snapshot.target_score);
      ("target_reached", `Bool snapshot.target_reached);
      ("compaction_count", `Int snapshot.compaction_count);
      ("handoff_count", `Int snapshot.handoff_count);
      ( "continuity_goal_matches",
        json_of_option (fun x -> `Bool x) snapshot.continuity_goal_matches );
      ( "continuity_task_matches",
        json_of_option (fun x -> `Bool x) snapshot.continuity_task_matches );
      ("reason", json_of_option (fun x -> `String x) snapshot.reason);
    ]
  in
  let fields =
    match verdict_of_phase snapshot.phase with
    | Some verdict -> ("verdict", `String verdict) :: fields
    | None -> fields
  in
  `Assoc (List.rev fields)

let event_to_yojson = function
  | Bootstrap_ok { goal } ->
    `Assoc [ ("event", `String "bootstrap_ok"); ("goal", `String goal) ]
  | Task_bound_observed { task_id; current_task_id } ->
    `Assoc
      [
        ("event", `String "task_bound_observed");
        ("task_id", `String task_id);
        ("current_task_id", `String current_task_id);
      ]
  | Autoresearch_started { loop_id; target_score } ->
    `Assoc
      [
        ("event", `String "autoresearch_started");
        ("loop_id", `String loop_id);
        ("target_score", json_of_option (fun x -> `Float x) target_score);
      ]
  | Target_reached_event ->
    `Assoc [ ("event", `String "target_reached") ]
  | Pressure_started ->
    `Assoc [ ("event", `String "pressure_started") ]
  | Compaction_observed { count } ->
    `Assoc
      [ ("event", `String "compaction_observed"); ("count", `Int count) ]
  | Handoff_observed { count; generation; trace_id } ->
    `Assoc
      [
        ("event", `String "handoff_observed");
        ("count", `Int count);
        ("generation", json_of_option (fun x -> `Int x) generation);
        ("trace_id", json_of_option (fun x -> `String x) trace_id);
      ]
  | Continuity_observed { goal_matches; current_task_id } ->
    `Assoc
      [
        ("event", `String "continuity_observed");
        ("goal_matches", `Bool goal_matches);
        ("current_task_id", json_of_option (fun x -> `String x) current_task_id);
      ]
  | Window_exhausted { reason } ->
    `Assoc
      [ ("event", `String "window_exhausted"); ("reason", `String reason) ]
  | Error_observed { reason } ->
    `Assoc
      [ ("event", `String "error_observed"); ("reason", `String reason) ]

let get_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)

let get_string name fields =
  match get_field name fields with
  | Ok (`String value) -> Ok value
  | Ok _ -> Error ("expected string field: " ^ name)
  | Error _ as err -> err

let get_string_opt name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ("expected string|null field: " ^ name)

let get_bool name fields =
  match get_field name fields with
  | Ok (`Bool value) -> Ok value
  | Ok _ -> Error ("expected bool field: " ^ name)
  | Error _ as err -> err

let get_int name fields =
  match get_field name fields with
  | Ok (`Int value) -> Ok value
  | Ok _ -> Error ("expected int field: " ^ name)
  | Error _ as err -> err

let get_int_opt name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Int value) -> Ok (Some value)
  | Some _ -> Error ("expected int|null field: " ^ name)

let get_float_opt name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Float value) -> Ok (Some value)
  | Some (`Int value) -> Ok (Some (float_of_int value))
  | Some _ -> Error ("expected number|null field: " ^ name)

let event_of_yojson_result = function
  | `Assoc fields -> (
      match get_string "event" fields with
      | Error _ as err -> err
      | Ok "bootstrap_ok" ->
        Result.map (fun goal -> Bootstrap_ok { goal }) (get_string "goal" fields)
      | Ok "task_bound_observed" ->
        let* task_id = get_string "task_id" fields in
        let* current_task_id = get_string "current_task_id" fields in
        Ok (Task_bound_observed { task_id; current_task_id })
      | Ok "autoresearch_started" ->
        let* loop_id = get_string "loop_id" fields in
        let* target_score = get_float_opt "target_score" fields in
        Ok (Autoresearch_started { loop_id; target_score })
      | Ok "target_reached" -> Ok Target_reached_event
      | Ok "pressure_started" -> Ok Pressure_started
      | Ok "compaction_observed" ->
        Result.map (fun count -> Compaction_observed { count }) (get_int "count" fields)
      | Ok "handoff_observed" ->
        let* count = get_int "count" fields in
        let* generation = get_int_opt "generation" fields in
        let* trace_id = get_string_opt "trace_id" fields in
        Ok (Handoff_observed { count; generation; trace_id })
      | Ok "continuity_observed" ->
        let* goal_matches = get_bool "goal_matches" fields in
        let* current_task_id = get_string_opt "current_task_id" fields in
        Ok (Continuity_observed { goal_matches; current_task_id })
      | Ok "window_exhausted" ->
        Result.map (fun reason -> Window_exhausted { reason }) (get_string "reason" fields)
      | Ok "error_observed" ->
        Result.map (fun reason -> Error_observed { reason }) (get_string "reason" fields)
      | Ok other -> Error ("unknown event: " ^ other))
  | _ -> Error "expected JSON object"

let event_of_yojson json =
  match event_of_yojson_result json with
  | Ok event -> event
  | Error msg -> invalid_arg ("Keeper_campaign_fsm.event_of_yojson: " ^ msg)

let invalid snapshot event reason =
  Error
    (Printf.sprintf "invalid transition: %s + %s (%s)"
       (phase_to_string snapshot.phase) (event_to_string event) reason)

let apply_event snapshot event =
  if phase_terminal snapshot.phase then
    invalid snapshot event "terminal phase is absorbing"
  else
    match snapshot.phase, event with
    | Bootstrapping, Bootstrap_ok { goal } ->
      Ok { snapshot with phase = Claiming_task; goal = Some goal; reason = None }
    | Claiming_task, Task_bound_observed { task_id; current_task_id } ->
      Ok
        {
          snapshot with
          phase = Task_bound;
          task_id = Some task_id;
          current_task_id = Some current_task_id;
          reason = None;
        }
    | Task_bound, Autoresearch_started { loop_id; target_score } ->
      Ok
        {
          snapshot with
          phase = Searching;
          loop_id = Some loop_id;
          target_score;
          reason = None;
        }
    | Searching, Target_reached_event ->
      Ok
        {
          snapshot with
          phase = Target_reached;
          target_reached = true;
          reason = None;
        }
    | Target_reached, Pressure_started ->
      Ok { snapshot with phase = Pressure_testing; reason = None }
    | Pressure_testing, Compaction_observed { count } ->
      Ok
        {
          snapshot with
          compaction_count = max snapshot.compaction_count count;
          reason = None;
        }
    | Pressure_testing, Handoff_observed { count; generation = _; trace_id = _ } ->
      Ok
        {
          snapshot with
          handoff_count = max snapshot.handoff_count count;
          reason = None;
        }
    | Pressure_testing, Continuity_observed { goal_matches; current_task_id } ->
      let task_matches = continuity_task_matches snapshot current_task_id in
      let lifecycle_evidence =
        snapshot.compaction_count > 0 || snapshot.handoff_count > 0
      in
      let next_snapshot =
        {
          snapshot with
          current_task_id;
          continuity_goal_matches = Some goal_matches;
          continuity_task_matches = Some task_matches;
        }
      in
      if goal_matches && task_matches && lifecycle_evidence && snapshot.target_reached
      then
        Ok { next_snapshot with phase = Continuity_verified; reason = None }
      else
        let reasons =
          List.filter_map
            (fun (ok, msg) -> if ok then None else Some msg)
            [
              (goal_matches, "goal mismatch");
              (task_matches, "task mismatch");
              (lifecycle_evidence, "missing lifecycle evidence");
              (snapshot.target_reached, "target not reached");
            ]
        in
        Ok
          {
            next_snapshot with
            phase = Escalated;
            reason = Some (String.concat ", " reasons);
          }
    | (Claiming_task | Task_bound | Searching | Pressure_testing), Window_exhausted { reason } ->
      Ok { snapshot with phase = Stalled; reason = Some reason }
    | (Bootstrapping | Claiming_task | Task_bound | Searching | Target_reached
      | Pressure_testing), Error_observed { reason } ->
      Ok { snapshot with phase = Escalated; reason = Some reason }
    | Claiming_task, Bootstrap_ok _ ->
      invalid snapshot event "bootstrap can only happen once"
    | Task_bound, Task_bound_observed _ ->
      invalid snapshot event "task already bound"
    | Searching, Autoresearch_started _ ->
      invalid snapshot event "autoresearch already started"
    | Target_reached, Target_reached_event ->
      invalid snapshot event "target already reached"
    | Pressure_testing, Pressure_started ->
      invalid snapshot event "pressure already started"
    | _, _ ->
      invalid snapshot event "event not allowed in this phase"

let replay events =
  List.fold_left
    (fun acc event ->
      let* snapshot = acc in
      apply_event snapshot event)
    (Ok initial) events
