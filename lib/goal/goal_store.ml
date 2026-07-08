(* Goal store — shared planning goals with a dedicated lifecycle phase.
   Legacy [status] remains persisted for compatibility, but it is derived
   from [phase] on write and inferred on read for old rows. *)

let ( let* ) = Result.bind

type goal_status =
  | Active
  | Paused
  | Done
  | Dropped

let goal_status_to_yojson = function
  | Active -> `String "active"
  | Paused -> `String "paused"
  | Done -> `String "done"
  | Dropped -> `String "dropped"

let goal_status_of_yojson = function
  | `String "active" -> Ok Active
  | `String "paused" -> Ok Paused
  | `String "done" -> Ok Done
  | `String "dropped" -> Ok Dropped
  | j -> Error ("goal_status_of_yojson: " ^ Yojson.Safe.to_string j)

(* RFC-0294: the workspace-goal [horizon] (short/mid/long) and its dead
   refresh/snapshot scheduler ([refresh_mode], [snapshot_mode], and their
   yojson codecs) were removed. The cadence had no live caller; the only
   surviving horizon consumer (dashboard stagnation threshold) was re-based
   onto a single policy constant. *)

let clamp_priority p =
  max 1 (min 5 p)

type goal = {
  id : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  status : goal_status;
  phase : Goal_phase.t;
  verifier_policy : Goal_verification.goal_verifier_policy option;
  require_completion_approval : bool;
  active_verification_request_id : string option;
  parent_goal_id : string option;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string;
  updated_at : string;
}

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
      ("status", goal_status_to_yojson goal.status);
      ("phase", Goal_phase.to_yojson goal.phase);
      ( "verifier_policy",
        match goal.verifier_policy with
        | Some policy -> Goal_verification.goal_verifier_policy_to_yojson policy
        | None -> `Null );
      ("require_completion_approval", `Bool goal.require_completion_approval);
      ("active_verification_request_id", Json_util.string_opt_to_json goal.active_verification_request_id);
      ("parent_goal_id", Json_util.string_opt_to_json goal.parent_goal_id);
      ("last_review_note", Json_util.string_opt_to_json goal.last_review_note);
      ("last_review_at", Json_util.string_opt_to_json goal.last_review_at);
      ("created_at", `String goal.created_at);
      ("updated_at", `String goal.updated_at);
    ]

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
  | `Assoc _ as json ->
      begin
        match Json_util.assoc_member_opt "id" json, Json_util.assoc_member_opt "title" json with
        | Some (`String id), Some (`String title) ->
            let legacy_status =
              match Json_util.assoc_member_opt "status" json with
              | None | Some `Null -> Ok Active
              | Some status_json -> goal_status_of_yojson status_json
            in
            let phase =
              match Json_util.assoc_member_opt "phase" json with
              | None | Some `Null -> (
                  match legacy_status with
                  | Ok status -> Ok (phase_of_goal_status status)
                  | Error msg -> Error msg)
              | Some phase_json -> Goal_phase.of_yojson phase_json
            in
            let verifier_policy =
              match Json_util.assoc_member_opt "verifier_policy" json with
              | None | Some `Null -> Ok None
              | Some policy_json ->
                  Result.map
                    Option.some
                    (Goal_verification.goal_verifier_policy_of_yojson policy_json)
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
            begin
              match legacy_status, phase, verifier_policy, created_at, updated_at with
              | Ok _legacy_status, Ok phase, Ok verifier_policy, Ok created_at, Ok updated_at ->
                  Ok
                    (normalize_goal
                       {
                         id;
                         title;
                         metric = Json_util.get_string json "metric" ;
                         target_value = Json_util.get_string json "target_value" ;
                         due_date = Json_util.get_string json "due_date" ;
                         priority =
                           (match Json_util.assoc_member_opt "priority" json with
                           | Some (`Int value) -> clamp_priority value
                           | _ -> 3);
                         status = goal_status_of_phase phase;
                         phase;
                         verifier_policy;
                         require_completion_approval =
                           (match Json_util.assoc_member_opt "require_completion_approval" json with
                           | Some (`Bool value) -> value
                           | _ -> false);
                         active_verification_request_id =
                           Json_util.get_string json "active_verification_request_id" ;
                         parent_goal_id = Json_util.get_string json "parent_goal_id" ;
                         last_review_note = Json_util.get_string json "last_review_note" ;
                         last_review_at = Json_util.get_string json "last_review_at" ;
                         created_at;
                         updated_at;
                       })
              | Error msg, _, _, _, _
              | _, Error msg, _, _, _
              | _, _, Error msg, _, _
              | _, _, _, Error msg, _
              | _, _, _, _, Error msg ->
                  Error msg
            end
        | _ ->
            Error "goal_of_yojson: invalid goal"
      end
  | json ->
      Error ("goal_of_yojson: " ^ Yojson.Safe.to_string json)

and normalize_goal (goal : goal) =
  {
    goal with
    status = goal_status_of_phase goal.phase;
    active_verification_request_id =
      (* Enumerate every [Goal_phase.t] variant so the compiler flags any
         new phase added here. Only [Awaiting_verification] keeps an
         active verification request_id; all other phases clear it as part
         of [normalize_goal]. A future phase added to [Goal_phase.t] (e.g.
         a hypothetical [Awaiting_review]) that should also retain the
         request_id would silently inherit "clear" under the previous
         [_, _ -> None] catch-all. *)
      (match goal.phase, goal.active_verification_request_id with
      | Goal_phase.Awaiting_verification, request_id -> request_id
      | ( Goal_phase.Executing | Goal_phase.Awaiting_approval
        | Goal_phase.Blocked | Goal_phase.Paused
        | Goal_phase.Completed | Goal_phase.Dropped ), _ -> None);
  }

and goal_status_of_phase = function
  | Goal_phase.Executing
  | Goal_phase.Awaiting_verification
  | Goal_phase.Awaiting_approval ->
      Active
  | Goal_phase.Paused
  | Goal_phase.Blocked ->
      Paused
  | Goal_phase.Completed -> Done
  | Goal_phase.Dropped -> Dropped

and phase_of_goal_status = function
  | Active -> Goal_phase.Executing
  | Paused -> Goal_phase.Paused
  | Done -> Goal_phase.Completed
  | Dropped -> Goal_phase.Dropped

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

let parse_goal_status = function
  | Some s -> (
      match normalize_lower s with
      | "active" -> Some Active
      | "paused" -> Some Paused
      | "done" -> Some Done
      | "dropped" -> Some Dropped
      | _ -> None)
  | None -> None

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
         | Ok state -> { state with goals = List.map normalize_goal state.goals }
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
                        { state with goals = List.map normalize_goal state.goals }
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
                   { state with goals = List.map normalize_goal state.goals }
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
          let updated_goal = normalize_goal (f { goal with updated_at = now }) in
          let next_state =
            {
              version = state.version + 1;
              updated_at = now;
              goals = replace_goal state.goals updated_goal;
            }
          in
          let* () = write_state_result config next_state in
          Ok updated_goal)

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

let list_goals config ?status ?phase () =
  read_state config
  |> fun state -> state.goals
  |> List.filter (fun goal ->
         match status with
         | None -> true
         | Some status -> goal.status = status)
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
    ?priority ?status ?phase ?parent_goal_id ?verifier_policy
    ?require_completion_approval () =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "") then
    Error "title required for new goal"
  else
    let resolved_phase =
      match phase, status with
      | Some phase, Some status when phase <> phase_of_goal_status status ->
          Error "phase and legacy status disagree"
      | Some phase, _ -> Ok phase
      | None, Some status -> Ok (phase_of_goal_status status)
      | None, None -> Ok Goal_phase.Executing
    in
    match resolved_phase with
    | Error msg -> Error msg
    | Ok default_phase ->
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
        let state_result =
          update_state config (fun state ->
              match find_goal state.goals resolved_id with
              | Some existing ->
                  let next_phase =
                    match phase, status with
                    | Some phase, _ -> phase
                    | None, Some legacy_status -> phase_of_goal_status legacy_status
                    | None, None -> existing.phase
                  in
                  let next_goal =
                    normalize_goal
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
                        status = goal_status_of_phase next_phase;
                        phase = next_phase;
                        verifier_policy =
                          (match verifier_policy with
                          | Some _ -> verifier_policy
                          | None -> existing.verifier_policy);
                        require_completion_approval =
                          (match require_completion_approval with
                          | Some value -> value
                          | None -> existing.require_completion_approval);
                        active_verification_request_id =
                          existing.active_verification_request_id;
                        parent_goal_id =
                          (match parent_goal_id with
                          | Some _ -> parent_goal_id
                          | None -> existing.parent_goal_id);
                        updated_at = now;
                      }
                  in
                  {
                    version = state.version + 1;
                    updated_at = now;
                    goals = replace_goal state.goals next_goal;
                  }
              | None ->
                  let new_goal =
                    normalize_goal
                      {
                        id = resolved_id;
                        title = Option.value title ~default:"Untitled goal";
                        metric;
                        target_value;
                        due_date;
                        priority = clamp_priority (Option.value priority ~default:3);
                        status = goal_status_of_phase default_phase;
                        phase = default_phase;
                        verifier_policy;
                        require_completion_approval =
                          Option.value require_completion_approval ~default:false;
                        active_verification_request_id = None;
                        parent_goal_id;
                        last_review_note = None;
                        last_review_at = None;
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
        match state_result with
        | Error msg -> Error msg
        | Ok state ->
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
    active_count = count (fun goal -> goal.status = Active);
    paused_count = count (fun goal -> goal.status = Paused);
    done_count = count (fun goal -> goal.status = Done);
    dropped_count = count (fun goal -> goal.status = Dropped);
  }

(* RFC-0294: the horizon-driven refresh/snapshot scheduler ([snapshot],
   [parse_yyyy_mm_dd], [days_until], [should_refresh_goal], [reprioritize],
   [refresh], [has_scheduler_state]) was removed. It had no live caller and its
   cohort selector keyed on the now-deleted [horizon]. *)

let active_goals config =
  list_goals config ~status:Active ()
