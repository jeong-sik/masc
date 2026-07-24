(* Goal store — shared planning goals with a dedicated lifecycle phase.
   [phase] is the only persisted lifecycle representation (RFC-0352 slice 1).
   The legacy [status] duplicate was removed after a live-store measurement
   found zero rows without a [phase] field; during the transition window the
   decoder still accepts and ignores an incoming "status" field, and the
   full-file save converges the store to phase-only on first write. *)

let ( let* ) = Result.bind

(* RFC-0294: the workspace-goal [horizon] (short/mid/long) and its dead
   refresh/snapshot scheduler ([refresh_mode], [snapshot_mode], and their
   yojson codecs) were removed. The cadence had no live caller; the only
   surviving horizon consumer (dashboard stagnation threshold) was re-based
   onto a single policy constant. *)

let clamp_priority p =
  max 1 (min 5 p)

type completion_receipt =
  { evaluator_runtime : string
  ; reviewed_at : string
  ; reviewed_goal_updated_at : string
  ; review_prompt_sha256 : string
  ; completion_claim : string
  ; linked_task_ids : string list
  }

type completion_review_failure =
  | Rejected
  | Unavailable

type goal = {
  id : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  phase : Goal_phase.t;
  parent_goal_id : string option;
  last_review_note : string option;
  last_review_at : string option;
  completion_review_failure : completion_review_failure option;
  completion_receipt : completion_receipt option;
  created_at : string;
  updated_at : string;
}

let validate_completion_invariant goal =
  match goal.phase, goal.completion_receipt, goal.completion_review_failure with
  | Goal_phase.Completed, None, _ ->
    Error
      "completed Goal requires a configured semantic-review completion receipt"
  | (Goal_phase.Executing | Goal_phase.Blocked | Goal_phase.Paused | Goal_phase.Dropped),
    Some _,
    _ ->
    Error "non-completed Goal cannot retain a completion receipt"
  | Goal_phase.Completed, Some _, Some _ ->
    Error "completed Goal cannot retain a failed completion-review outcome"
  | _, _, Some _ when Option.is_none goal.last_review_note ->
    Error "failed completion-review outcome requires a durable review note"
  | Goal_phase.Completed, Some _, None
  | (Goal_phase.Executing | Goal_phase.Blocked | Goal_phase.Paused | Goal_phase.Dropped),
    None,
    _ ->
    Ok ()
;;

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
}

let rec state_to_yojson (state : state) =
  `Assoc
    [
      ("version", `Int state.version);
      ("updated_at", `String state.updated_at);
      ("goals", `List (List.map (fun goal -> goal_to_yojson goal) state.goals));
    ]

and goal_to_yojson (goal : goal) =
  `Assoc
    [
      ("id", `String goal.id);
      ("title", `String goal.title);
      ("metric", Json_util.string_opt_to_json goal.metric);
      ("target_value", Json_util.string_opt_to_json goal.target_value);
      ("due_date", Json_util.string_opt_to_json goal.due_date);
      ("priority", `Int goal.priority);
      ("phase", Goal_phase.to_yojson goal.phase);
      ("parent_goal_id", Json_util.string_opt_to_json goal.parent_goal_id);
      ("last_review_note", Json_util.string_opt_to_json goal.last_review_note);
      ("last_review_at", Json_util.string_opt_to_json goal.last_review_at);
      ( "completion_review_failure"
      , match goal.completion_review_failure with
        | None -> `Null
        | Some Rejected -> `String "rejected"
        | Some Unavailable -> `String "unavailable" );
      ( "completion_receipt"
      , match goal.completion_receipt with
        | None -> `Null
        | Some receipt -> completion_receipt_to_yojson receipt );
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]

and completion_receipt_to_yojson receipt =
  `Assoc
    [ "evaluator_runtime", `String receipt.evaluator_runtime
    ; "reviewed_at", `String receipt.reviewed_at
    ; "reviewed_goal_updated_at", `String receipt.reviewed_goal_updated_at
    ; "review_prompt_sha256", `String receipt.review_prompt_sha256
    ; "completion_claim", `String receipt.completion_claim
    ; ( "linked_task_ids"
      , `List (List.map (fun task_id -> `String task_id) receipt.linked_task_ids) )
    ]

and completion_receipt_of_yojson = function
  | `Assoc fields as json ->
    let accepted_fields =
      [ "evaluator_runtime"
      ; "reviewed_at"
      ; "reviewed_goal_updated_at"
      ; "review_prompt_sha256"
      ; "completion_claim"
      ; "linked_task_ids"
      ]
    in
    (match
       List.find_map
         (fun (field, _) ->
            if List.mem field accepted_fields then None else Some field)
         fields
     with
     | Some field ->
       Error
         (Printf.sprintf
            "completion_receipt_of_yojson: unknown field %S"
            field)
     | None ->
       (match
          ( Json_util.assoc_member_opt "evaluator_runtime" json
          , Json_util.assoc_member_opt "reviewed_at" json
          , Json_util.assoc_member_opt "reviewed_goal_updated_at" json
          , Json_util.assoc_member_opt "review_prompt_sha256" json
          , Json_util.assoc_member_opt "completion_claim" json
          , Json_util.assoc_member_opt "linked_task_ids" json )
        with
        | ( Some (`String evaluator_runtime)
          , Some (`String reviewed_at)
          , Some (`String reviewed_goal_updated_at)
          , Some (`String review_prompt_sha256)
          , Some (`String completion_claim)
          , Some (`List linked_task_ids_json) ) ->
          let rec parse_task_ids acc = function
            | [] -> Ok (List.rev acc)
            | `String task_id :: rest -> parse_task_ids (task_id :: acc) rest
            | _ :: _ ->
              Error
                "completion_receipt_of_yojson: linked_task_ids must contain \
                 only strings"
          in
          Result.map
            (fun linked_task_ids ->
               { evaluator_runtime
               ; reviewed_at
               ; reviewed_goal_updated_at
               ; review_prompt_sha256
               ; completion_claim
               ; linked_task_ids
               })
            (parse_task_ids [] linked_task_ids_json)
        | _ -> Error "completion_receipt_of_yojson: invalid receipt"))
  | _ -> Error "completion_receipt_of_yojson: expected object"

and state_of_yojson = function
  | `Assoc _ as json ->
      begin
        match Json_util.assoc_member_opt "version" json, Json_util.assoc_member_opt "updated_at" json, Json_util.assoc_member_opt "goals" json with
        | Some (`Int version), Some (`String updated_at), Some (`List goals_json) ->
            let rec collect acc = function
              | [] -> Ok (List.rev acc)
              | row :: rest -> (
                  match goal_of_yojson row with
                  | Ok goal -> collect (goal :: acc) rest
                  | Error msg -> Error msg)
            in
            Result.map
              (fun goals -> { version; updated_at; goals })
              (collect [] goals_json)
        | _ -> Error "state_of_yojson: invalid state"
      end
  | json ->
      Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)

and goal_of_yojson = function
  | `Assoc fields as json ->
      let accepted_fields =
        [ "id"
        ; "title"
        ; "metric"
        ; "target_value"
        ; "due_date"
        ; "priority"
        ; "status" (* accepted and ignored during the phase-only transition:
                        rows written before RFC-0352 slice 1 still carry the
                        derived duplicate until the first full-file save *)
        ; "phase"
        ; "parent_goal_id"
        ; "last_review_note"
        ; "last_review_at"
        ; "completion_review_failure"
        ; "completion_receipt"
        ; "created_at"
        ; "updated_at"
        ]
      in
      let unknown_field =
        List.find_map
          (fun (field, _) ->
            if List.mem field accepted_fields then None else Some field)
          fields
      in
      let id_opt = Json_util.assoc_member_opt "id" json in
      let title_opt = Json_util.assoc_member_opt "title" json in
      (match unknown_field, id_opt, title_opt with
      | Some field, _, _ ->
          Error
            (Printf.sprintf
               "goal_of_yojson: unknown Goal field %S is not accepted"
               field)
      | None, Some (`String id), Some (`String title) ->
          let phase =
            (* Phase is required. The status->phase read inference for
               pre-phase rows was removed in RFC-0352 slice 1 after a live
               measurement found zero phase-less rows; a row without [phase]
               is now a decode error rather than a silent Active default
               (the silent default already caused main red #23901 once). *)
            match Json_util.assoc_member_opt "phase" json with
            | None | Some `Null ->
                Error
                  (Printf.sprintf
                     "goal_of_yojson: goal %S has no phase field (legacy \
                      status-only rows no longer decode; RFC-0352 slice 1)"
                     id)
            | Some phase_json -> Goal_phase.of_yojson phase_json
          in
          let created_at =
            match Json_util.assoc_member_opt "created_at" json with
            | Some (`String value) -> Ok value
            | _ -> Error "goal_of_yojson: created_at missing"
          in
          let updated_at =
            match Json_util.assoc_member_opt "updated_at" json with
            | Some (`String value) -> Ok value
            | _ -> Error "goal_of_yojson: updated_at missing"
          in
          let completion_receipt =
            match Json_util.assoc_member_opt "completion_receipt" json with
            | None | Some `Null -> Ok None
            | Some receipt_json ->
              Result.map
                (fun receipt -> Some receipt)
                (completion_receipt_of_yojson receipt_json)
          in
          let completion_review_failure =
            match Json_util.assoc_member_opt "completion_review_failure" json with
            | None | Some `Null -> Ok None
            | Some (`String "rejected") -> Ok (Some Rejected)
            | Some (`String "unavailable") -> Ok (Some Unavailable)
            | Some _ ->
              Error
                "goal_of_yojson: completion_review_failure must be rejected or \
                 unavailable"
          in
          (match
             ( phase
             , created_at
             , updated_at
             , completion_receipt
             , completion_review_failure )
           with
           | ( Ok phase
             , Ok created_at
             , Ok updated_at
             , Ok completion_receipt
             , Ok completion_review_failure ) ->
             let goal =
               {
                    id;
                    title;
                    metric = Json_util.get_string json "metric";
                    target_value = Json_util.get_string json "target_value";
                    due_date = Json_util.get_string json "due_date";
                    priority =
                      (match Json_util.assoc_member_opt "priority" json with
                      | Some (`Int value) -> clamp_priority value
                      | _ -> 3);
                    phase;
                    parent_goal_id = Json_util.get_string json "parent_goal_id";
                    last_review_note = Json_util.get_string json "last_review_note";
                    last_review_at = Json_util.get_string json "last_review_at";
                    completion_review_failure;
                    completion_receipt;
                    created_at;
                    updated_at;
                  }
             in
             Ok goal
           | Error msg, _, _, _, _ -> Error msg
           | _, Error msg, _, _, _ -> Error msg
           | _, _, Error msg, _, _ -> Error msg
           | _, _, _, Error msg, _ -> Error msg
           | _, _, _, _, Error msg -> Error msg)
      | None, _, _ -> Error "goal_of_yojson: invalid goal")
  | other_json ->
      Error ("goal_of_yojson: " ^ Yojson.Safe.to_string other_json)

type rollup = {
  active_count : int;
  paused_count : int;
  done_count : int;
  dropped_count : int;
}
[@@deriving yojson]

type upsert_kind = [ `created | `updated ]

let normalize_lower s =
  String.trim s |> String.lowercase_ascii

let parse_goal_phase = function
  | Some s -> Goal_phase.parse s
  | None -> None

let goals_path config =
  Filename.concat (Workspace_utils.masc_dir config) "goals.json"

let goals_recovery_path config =
  goals_path config ^ ".last-good"

let ensure_dirs config =
  Workspace_utils.mkdir_p (Workspace_utils.masc_dir config)

let default_state () =
  { version = 1; updated_at = Masc_domain.now_iso (); goals = [] }

let read_state config =
  ensure_dirs config;
  let path = goals_path config in
  if Workspace_utils.path_exists config path then
    match Workspace_utils.read_json_result config path with
    | Ok json ->
        (match state_of_yojson json with
         | Ok state -> state
         | Error primary_msg ->
             let recovery = goals_recovery_path config in
             if Workspace_utils.path_exists config recovery then
               match Workspace_utils.read_json_result config recovery with
               | Ok recovery_json ->
                   (match state_of_yojson recovery_json with
                    | Ok state ->
                        Log.Misc.warn
                          "goal_store: primary goals.json corrupt (%s), recovered from %s"
                          primary_msg recovery;
                        state
                    | Error recovery_msg ->
                        Log.Misc.error
                          "goal_store: both primary and recovery goals.json corrupt (primary: %s, recovery: %s)"
                          primary_msg recovery_msg;
                        default_state ())
               | Error recovery_read_msg ->
                   Log.Misc.warn
                     "goal_store: goals.json corrupt (%s), recovery read failed: %s"
                     primary_msg recovery_read_msg;
                   default_state ()
             else
               (Log.Misc.warn
                  "goal_store: goals.json corrupt (%s), no .last-good available"
                  primary_msg;
                default_state ()))
    | Error primary_msg ->
        let recovery = goals_recovery_path config in
        if Workspace_utils.path_exists config recovery then
          match Workspace_utils.read_json_result config recovery with
          | Ok recovery_json ->
              (match state_of_yojson recovery_json with
               | Ok state ->
                   Log.Misc.warn
                     "goal_store: primary goals.json unreadable (%s), recovered from %s"
                     primary_msg recovery;
                   state
               | Error recovery_msg ->
                   Log.Misc.error
                     "goal_store: primary unreadable (%s), recovery corrupt (%s)"
                     primary_msg recovery_msg;
                   default_state ())
          | Error recovery_msg ->
              Log.Misc.error
                "goal_store: primary unreadable (%s), recovery unreadable (%s)"
                primary_msg recovery_msg;
              default_state ()
        else
          (Log.Misc.warn
             "goal_store: goals.json unreadable (%s), no .last-good available"
             primary_msg;
           default_state ())
  else
    default_state ()

let write_state_result config state =
  ensure_dirs config;
  let json = state_to_yojson state in
  let* () = Workspace_utils.write_json_result config (goals_path config) json in
  (match Workspace_utils.write_json_result config (goals_recovery_path config) json with
   | Ok () -> ()
   | Error msg ->
     Log.Misc.warn
       "goal_store: primary goals.json committed; recovery mirror write failed for %s: %s"
       (goals_recovery_path config)
       msg);
  Ok ()

let write_state config state =
  match write_state_result config state with
  | Ok () -> ()
  | Error msg ->
    Log.Misc.warn "goal_store.write_state failed for %s: %s"
      (goals_path config)
      msg

let now_ms () =
  int_of_float (Time_compat.now () *. 1000.0)

let gen_goal_id () =
  Printf.sprintf "goal-%d-%04x" (now_ms ())
    (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF)

let find_goal goals id =
  List.find_opt (fun goal -> String.equal goal.id id) goals

let replace_goal goals updated =
  List.map (fun goal -> if String.equal goal.id updated.id then updated else goal) goals

let update_state config f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let state = read_state config in
      let next_state = f state in
      let* () = write_state_result config next_state in
      Ok next_state)

let get_goal config ~goal_id =
  read_state config |> fun state -> find_goal state.goals goal_id

let update_goal config ~goal_id f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
      let state = read_state config in
      match find_goal state.goals goal_id with
      | None -> Error "goal not found"
      | Some goal ->
          let now = Masc_domain.now_iso () in
          let updated_goal = f { goal with updated_at = now } in
          let* () = validate_completion_invariant updated_goal in
          let next_state =
            {
              version = state.version + 1;
              updated_at = now;
              goals = replace_goal state.goals updated_goal;
            }
          in
          let* () = write_state_result config next_state in
          Ok updated_goal)

type conditional_update_error =
  | Goal_not_found
  | Goal_snapshot_changed
  | Goal_persistence_failed of string

let conditional_update_error_to_string = function
  | Goal_not_found -> "goal not found"
  | Goal_snapshot_changed ->
    "Goal changed while completion was being reviewed; obtain a new verdict \
     for the current Goal snapshot"
  | Goal_persistence_failed msg -> msg
;;

let update_goal_if_unchanged config ~(expected : goal) f =
  let lock_path = goals_path config in
  Workspace_utils.with_file_lock config lock_path (fun () ->
    let state = read_state config in
    match find_goal state.goals expected.id with
    | None -> Error Goal_not_found
    | Some current when current <> expected -> Error Goal_snapshot_changed
    | Some current ->
      let now = Masc_domain.now_iso () in
      let updated_goal = f { current with updated_at = now } in
      (match validate_completion_invariant updated_goal with
       | Error msg -> Error (Goal_persistence_failed msg)
       | Ok () ->
         let next_state =
           { version = state.version + 1
           ; updated_at = now
           ; goals = replace_goal state.goals updated_goal
           }
         in
         (match write_state_result config next_state with
          | Ok () -> Ok updated_goal
          | Error msg -> Error (Goal_persistence_failed msg))))

type delete_goal_outcome =
  | Deleted
  | Deleted_with_orphaned_links of string

type delete_goal_error =
  | Unknown_goal of string
  | Persistence_failed of string

let delete_goal_error_to_string = function
  | Unknown_goal msg -> msg
  | Persistence_failed msg -> "goal persistence failed: " ^ msg

let delete_goal config ~goal_id =
  let deleted =
    Workspace_utils.with_file_lock config (goals_path config) (fun () ->
      let state = read_state config in
      if not (List.exists (fun goal -> String.equal goal.id goal_id) state.goals) then
        Error (Unknown_goal "Goal not found")
      else (
        match
          write_state_result
            config
            { version = state.version + 1
            ; goals =
                List.filter
                  (fun goal -> not (String.equal goal.id goal_id))
                  state.goals
            ; updated_at = Masc_domain.now_iso ()
            }
        with
        | Ok () -> Ok ()
        | Error msg -> Error (Persistence_failed msg)))
  in
  match deleted with
  | Error _ as error -> error
  | Ok () ->
    (* This is best-effort cascade cleanup across two file stores, not a
       cross-file transaction. A structural fix would either co-locate
       goal-task links with goals or add a higher-level transaction lock that
       covers every goal/link mutation path. *)
    (match Workspace_goal_index.prune_links_for_goal_result config ~goal_id with
     | Ok () -> Ok Deleted
     | Error detail ->
       Log.Misc.warn
         "goal_store.delete_goal: goal %s removed but goal_task_links prune failed: %s"
         goal_id
         detail;
       let warning =
         Printf.sprintf
           "goal deleted but failed to prune goal_task_links for %s: %s"
           goal_id
           detail
       in
       Ok (Deleted_with_orphaned_links warning))

let sort_goals goals =
  (* RFC-0294: sort key was [(horizon, priority, updated_at desc)]; with horizon
     removed it collapses to [(priority asc, updated_at desc)]. *)
  List.sort
    (fun left right ->
      let by_priority = compare left.priority right.priority in
      if by_priority <> 0 then
        by_priority
      else
        String.compare right.updated_at left.updated_at)
    goals

let list_goals config ?phase () =
  read_state config
  |> fun state -> state.goals
  |> List.filter (fun goal ->
         match phase with
         | None -> true
         | Some phase -> goal.phase = phase)
  |> sort_goals

let validate_parent_goal_id goals ~goal_id ~parent_goal_id =
  (* Cannot be own parent *)
  if String.equal goal_id parent_goal_id then
    Error "goal cannot be its own parent"
  else
    (* Parent must exist *)
    match find_goal goals parent_goal_id with
    | None -> Error (Printf.sprintf "parent goal %s not found" parent_goal_id)
    | Some _ ->
      (* Walk ancestor chain to detect cycles *)
      let rec walk visited current_id =
        if String.equal current_id goal_id then
          true (* cycle detected *)
        else
          match find_goal goals current_id with
          | None -> false (* orphan parent, already checked above *)
          | Some g ->
            match g.parent_goal_id with
            | None -> false
            | Some pid ->
              if List.mem pid visited then
                false (* existing cycle in ancestors, don't add to it *)
              else
                walk (pid :: visited) pid
      in
      if walk [parent_goal_id] parent_goal_id then
        Error "parent_goal_id would create a cycle"
      else
        Ok ()

let upsert_goal config ?id ?title ?metric ?target_value ?due_date
    ?priority ?parent_goal_id () =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "") then
    Error "title required for new goal"
  else
    let now = Masc_domain.now_iso () in
        let resolved_id = Option.value id ~default:(gen_goal_id ()) in
        (* Validate parent_goal_id before acquiring the write lock *)
        let parent_validation =
          let current_goals = (read_state config).goals in
          match find_goal current_goals resolved_id with
          | Some existing ->
              (* Existing goal: validate only if parent is being changed *)
              (match parent_goal_id with
               | Some new_pid ->
                   (match existing.parent_goal_id with
                    | Some old_pid when String.equal old_pid new_pid ->
                        Ok () (* no change, skip validation *)
                    | _ ->
                        validate_parent_goal_id current_goals
                          ~goal_id:resolved_id
                          ~parent_goal_id:new_pid)
               | None -> Ok ())
          | None ->
              (* New goal: validate any provided parent_goal_id *)
              (match parent_goal_id with
               | Some pid ->
                   validate_parent_goal_id current_goals
                     ~goal_id:resolved_id
                     ~parent_goal_id:pid
               | None -> Ok ())
        in
        (match parent_validation with
         | Error msg -> Error msg
         | Ok () ->
        let was_created = ref false in
        let mutation_rejection = ref None in
        let state_result =
          update_state config (fun state ->
              match find_goal state.goals resolved_id with
              | Some existing ->
                  let candidate_goal =
                      {
                        existing with
                        title = Option.value title ~default:existing.title;
                        metric = (match metric with Some _ -> metric | None -> existing.metric);
                        target_value =
                          (match target_value with
                          | Some _ -> target_value
                          | None -> existing.target_value);
                        due_date =
                          (match due_date with
                          | Some _ -> due_date
                          | None -> existing.due_date);
                        priority =
                          clamp_priority
                            (Option.value priority ~default:existing.priority);
                        parent_goal_id =
                          (match parent_goal_id with
                          | Some _ -> parent_goal_id
                          | None -> existing.parent_goal_id);
                      }
                  in
                  if candidate_goal = existing
                  then state
                  else if existing.phase = Goal_phase.Completed
                  then (
                    mutation_rejection :=
                      Some
                        "completed Goal metadata is immutable; reopen the Goal \
                         before changing its completion contract";
                    state)
                  else
                    let next_goal = { candidate_goal with updated_at = now } in
                    {
                      version = state.version + 1;
                      updated_at = now;
                      goals = replace_goal state.goals next_goal;
                    }
              | None ->
                  let new_goal =
                      {
                        id = resolved_id;
                        title = Option.value title ~default:"Untitled goal";
                        metric;
                        target_value;
                        due_date;
                        priority = clamp_priority (Option.value priority ~default:3);
                        phase = Goal_phase.Executing;
                        parent_goal_id;
                        last_review_note = None;
                        last_review_at = None;
                        completion_review_failure = None;
                        completion_receipt = None;
                        created_at = now;
                        updated_at = now;
                      }
                  in
                  was_created := true;
                  {
                    version = state.version + 1;
                    updated_at = now;
                    goals = state.goals @ [ new_goal ];
                  })
        in
        match !mutation_rejection, state_result with
        | Some msg, _ -> Error msg
        | None, Error msg -> Error msg
        | None, Ok state ->
          match find_goal state.goals resolved_id with
          | Some goal ->
              Ok (goal, if !was_created then `created else `updated)
          | None ->
              Error "failed to save goal")

let compute_rollup goals =
  let count predicate =
    List_util.count_if predicate goals
  in
  {
    active_count = count (fun goal -> goal.phase = Goal_phase.Executing);
    paused_count =
      count (fun goal ->
          match goal.phase with
          | Goal_phase.Paused | Goal_phase.Blocked -> true
          | _ -> false);
    done_count = count (fun goal -> goal.phase = Goal_phase.Completed);
    dropped_count = count (fun goal -> goal.phase = Goal_phase.Dropped);
  }

(* RFC-0294: the horizon-driven refresh/snapshot scheduler ([snapshot],
   [parse_yyyy_mm_dd], [days_until], [should_refresh_goal], [reprioritize],
   [refresh], [has_scheduler_state]) was removed. It had no live caller and its
   cohort selector keyed on the now-deleted [horizon]. *)

let active_goals config =
  list_goals config ~phase:Goal_phase.Executing ()
