(* Goal store — shared planning goals with a dedicated lifecycle phase.
   Legacy [status] remains persisted for compatibility, but it is derived
   from [phase] on write and inferred on read for old rows. *)

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
;;

let goal_status_of_yojson = function
  | `String "active" -> Ok Active
  | `String "paused" -> Ok Paused
  | `String "done" -> Ok Done
  | `String "dropped" -> Ok Dropped
  | j -> Error ("goal_status_of_yojson: " ^ Yojson.Safe.to_string j)
;;

type horizon =
  | Short
  | Mid
  | Long

let horizon_to_yojson = function
  | Short -> `String "short"
  | Mid -> `String "mid"
  | Long -> `String "long"
;;

let horizon_of_yojson = function
  | `String "short" -> Ok Short
  | `String "mid" -> Ok Mid
  | `String "long" -> Ok Long
  | j -> Error ("horizon_of_yojson: " ^ Yojson.Safe.to_string j)
;;

type refresh_mode =
  | Daily
  | Weekly
  | Monthly

let refresh_mode_to_yojson = function
  | Daily -> `String "daily"
  | Weekly -> `String "weekly"
  | Monthly -> `String "monthly"
;;

let refresh_mode_of_yojson = function
  | `String "daily" -> Ok Daily
  | `String "weekly" -> Ok Weekly
  | `String "monthly" -> Ok Monthly
  | j -> Error ("refresh_mode_of_yojson: " ^ Yojson.Safe.to_string j)
;;

type snapshot_mode =
  | SnapDaily
  | SnapWeekly
  | SnapMonthly
  | SnapManual

let snapshot_mode_to_yojson = function
  | SnapDaily -> `String "daily"
  | SnapWeekly -> `String "weekly"
  | SnapMonthly -> `String "monthly"
  | SnapManual -> `String "manual"
;;

let snapshot_mode_of_yojson = function
  | `String "daily" -> Ok SnapDaily
  | `String "weekly" -> Ok SnapWeekly
  | `String "monthly" -> Ok SnapMonthly
  | `String "manual" -> Ok SnapManual
  | j -> Error ("snapshot_mode_of_yojson: " ^ Yojson.Safe.to_string j)
;;

let snapshot_mode_of_refresh_mode = function
  | Daily -> SnapDaily
  | Weekly -> SnapWeekly
  | Monthly -> SnapMonthly
;;

let parse_snapshot_mode s =
  match String.trim s |> String.lowercase_ascii with
  | "daily" -> Some SnapDaily
  | "weekly" -> Some SnapWeekly
  | "monthly" -> Some SnapMonthly
  | "manual" -> Some SnapManual
  | _ -> None
;;

type review_outcome =
  | ReviewDone
  | ReviewProgress
  | ReviewBlocked
  | ReviewDropped

let review_outcome_to_yojson = function
  | ReviewDone -> `String "done"
  | ReviewProgress -> `String "progress"
  | ReviewBlocked -> `String "blocked"
  | ReviewDropped -> `String "dropped"
;;

let review_outcome_of_yojson = function
  | `String "done" -> Ok ReviewDone
  | `String "progress" -> Ok ReviewProgress
  | `String "blocked" -> Ok ReviewBlocked
  | `String "dropped" -> Ok ReviewDropped
  | j -> Error ("review_outcome_of_yojson: " ^ Yojson.Safe.to_string j)
;;

let clamp_priority p = max 1 (min 5 p)

type goal =
  { id : string
  ; horizon : horizon
  ; title : string
  ; metric : string option
  ; target_value : string option
  ; due_date : string option
  ; priority : int
  ; status : goal_status
  ; phase : Goal_phase.t
  ; verifier_policy : Goal_verification.goal_verifier_policy option
  ; require_completion_approval : bool
  ; active_verification_request_id : string option
  ; parent_goal_id : string option
  ; last_review_note : string option
  ; last_review_at : string option
  ; created_at : string
  ; updated_at : string
  }

type state =
  { version : int
  ; updated_at : string
  ; goals : goal list
  }

let rec state_to_yojson (state : state) =
  `Assoc
    [ "version", `Int state.version
    ; "updated_at", `String state.updated_at
    ; "goals", `List (List.map (fun goal -> goal_to_yojson goal) state.goals)
    ]

and goal_to_yojson (goal : goal) =
  `Assoc
    [ "id", `String goal.id
    ; "horizon", horizon_to_yojson goal.horizon
    ; "title", `String goal.title
    ; ( "metric"
      , match goal.metric with
        | Some value -> `String value
        | None -> `Null )
    ; ( "target_value"
      , match goal.target_value with
        | Some value -> `String value
        | None -> `Null )
    ; ( "due_date"
      , match goal.due_date with
        | Some value -> `String value
        | None -> `Null )
    ; "priority", `Int goal.priority
    ; "status", goal_status_to_yojson goal.status
    ; "phase", Goal_phase.to_yojson goal.phase
    ; ( "verifier_policy"
      , match goal.verifier_policy with
        | Some policy -> Goal_verification.goal_verifier_policy_to_yojson policy
        | None -> `Null )
    ; "require_completion_approval", `Bool goal.require_completion_approval
    ; ( "active_verification_request_id"
      , match goal.active_verification_request_id with
        | Some value -> `String value
        | None -> `Null )
    ; ( "parent_goal_id"
      , match goal.parent_goal_id with
        | Some value -> `String value
        | None -> `Null )
    ; ( "last_review_note"
      , match goal.last_review_note with
        | Some value -> `String value
        | None -> `Null )
    ; ( "last_review_at"
      , match goal.last_review_at with
        | Some value -> `String value
        | None -> `Null )
    ; "created_at", `String goal.created_at
    ; "updated_at", `String goal.updated_at
    ]

and state_of_yojson = function
  | `Assoc _ as json ->
    let open Yojson.Safe.Util in
    (match member "version" json, member "updated_at" json, member "goals" json with
     | `Int version, `String updated_at, `List goals_json ->
       let rec collect acc = function
         | [] -> Ok (List.rev acc)
         | row :: rest ->
           (match goal_of_yojson row with
            | Ok goal -> collect (goal :: acc) rest
            | Error msg -> Error msg)
       in
       Result.map (fun goals -> { version; updated_at; goals }) (collect [] goals_json)
     | _ -> Error "state_of_yojson: invalid state")
  | json -> Error ("state_of_yojson: " ^ Yojson.Safe.to_string json)

and goal_of_yojson = function
  | `Assoc _ as json ->
    let open Yojson.Safe.Util in
    (match
       member "id" json, horizon_of_yojson (member "horizon" json), member "title" json
     with
     | `String id, Ok horizon, `String title ->
       let legacy_status =
         match member "status" json with
         | `Null -> Ok Active
         | status_json -> goal_status_of_yojson status_json
       in
       let phase =
         match member "phase" json with
         | `Null ->
           (match legacy_status with
            | Ok status -> Ok (phase_of_goal_status status)
            | Error msg -> Error msg)
         | phase_json -> Goal_phase.of_yojson phase_json
       in
       let verifier_policy =
         match member "verifier_policy" json with
         | `Null -> Ok None
         | policy_json ->
           Result.map
             Option.some
             (Goal_verification.goal_verifier_policy_of_yojson policy_json)
       in
       let created_at =
         match member "created_at" json with
         | `String value -> Ok value
         | _ -> Error "goal_of_yojson: created_at missing"
       in
       let updated_at =
         match member "updated_at" json with
         | `String value -> Ok value
         | _ -> Error "goal_of_yojson: updated_at missing"
       in
       (match legacy_status, phase, verifier_policy, created_at, updated_at with
        | Ok _legacy_status, Ok phase, Ok verifier_policy, Ok created_at, Ok updated_at ->
          Ok
            (normalize_goal
               { id
               ; horizon
               ; title
               ; metric = member "metric" json |> to_string_option
               ; target_value = member "target_value" json |> to_string_option
               ; due_date = member "due_date" json |> to_string_option
               ; priority =
                   (match member "priority" json with
                    | `Int value -> clamp_priority value
                    | _ -> 3)
               ; status = goal_status_of_phase phase
               ; phase
               ; verifier_policy
               ; require_completion_approval =
                   (match member "require_completion_approval" json with
                    | `Bool value -> value
                    | _ -> false)
               ; active_verification_request_id =
                   member "active_verification_request_id" json |> to_string_option
               ; parent_goal_id = member "parent_goal_id" json |> to_string_option
               ; last_review_note = member "last_review_note" json |> to_string_option
               ; last_review_at = member "last_review_at" json |> to_string_option
               ; created_at
               ; updated_at
               })
        | Error msg, _, _, _, _
        | _, Error msg, _, _, _
        | _, _, Error msg, _, _
        | _, _, _, Error msg, _
        | _, _, _, _, Error msg -> Error msg)
     | _ -> Error "goal_of_yojson: invalid goal")
  | json -> Error ("goal_of_yojson: " ^ Yojson.Safe.to_string json)

and normalize_goal (goal : goal) =
  { goal with
    status = goal_status_of_phase goal.phase
  ; active_verification_request_id =
      (match goal.phase, goal.active_verification_request_id with
       | Goal_phase.Awaiting_verification, request_id -> request_id
       | _, _ -> None)
  }

and goal_status_of_phase = function
  | Goal_phase.Executing | Goal_phase.Awaiting_verification | Goal_phase.Awaiting_approval
    -> Active
  | Goal_phase.Paused | Goal_phase.Blocked -> Paused
  | Goal_phase.Completed -> Done
  | Goal_phase.Dropped -> Dropped

and phase_of_goal_status = function
  | Active -> Goal_phase.Executing
  | Paused -> Goal_phase.Paused
  | Done -> Goal_phase.Completed
  | Dropped -> Goal_phase.Dropped
;;

type rollup =
  { short_count : int
  ; mid_count : int
  ; long_count : int
  ; active_count : int
  ; paused_count : int
  ; done_count : int
  ; dropped_count : int
  }
[@@deriving yojson]

type snapshot =
  { snapshot_id : string
  ; created_at : string
  ; mode : snapshot_mode
  ; goals : goal list
  ; rollup : rollup
  }
[@@deriving yojson]

type upsert_kind =
  [ `created
  | `updated
  ]

type refresh_result =
  { mode : refresh_mode
  ; scanned : int
  ; updated : int
  ; snapshot_id : string
  }
[@@deriving yojson]

let normalize_lower s = String.trim s |> String.lowercase_ascii

let parse_horizon = function
  | Some s ->
    (match normalize_lower s with
     | "short" -> Some Short
     | "mid" -> Some Mid
     | "long" -> Some Long
     | _ -> None)
  | None -> None
;;

let parse_goal_status = function
  | Some s ->
    (match normalize_lower s with
     | "active" -> Some Active
     | "paused" -> Some Paused
     | "done" -> Some Done
     | "dropped" -> Some Dropped
     | _ -> None)
  | None -> None
;;

let parse_goal_phase = function
  | Some s -> Goal_phase.parse s
  | None -> None
;;

let parse_refresh_mode s =
  match normalize_lower s with
  | "daily" -> Some Daily
  | "weekly" -> Some Weekly
  | "monthly" -> Some Monthly
  | _ -> None
;;

let parse_review_outcome s =
  match normalize_lower s with
  | "done" -> Some ReviewDone
  | "progress" -> Some ReviewProgress
  | "blocked" -> Some ReviewBlocked
  | "dropped" -> Some ReviewDropped
  | _ -> None
;;

let goals_path config = Filename.concat (Coord.masc_dir config) "goals.json"
let snapshots_dir config = Filename.concat (Coord.masc_dir config) "goals_snapshots"

let scheduler_state_path config =
  Filename.concat (Coord.masc_dir config) "goals_scheduler_state.json"
;;

let ensure_dirs config =
  Coord.mkdir_p (Coord.masc_dir config);
  Coord.mkdir_p (snapshots_dir config)
;;

let default_state () = { version = 1; updated_at = Types.now_iso (); goals = [] }

let read_state config =
  ensure_dirs config;
  let path = goals_path config in
  if Coord.path_exists config path
  then (
    match state_of_yojson (Coord.read_json config path) with
    | Ok state -> { state with goals = List.map normalize_goal state.goals }
    | Error _ -> default_state ())
  else default_state ()
;;

let write_state config state =
  ensure_dirs config;
  Coord.write_json config (goals_path config) (state_to_yojson state)
;;

let now_ms () = int_of_float (Time_compat.now () *. 1000.0)

let gen_goal_id () =
  Printf.sprintf
    "goal-%d-%04x"
    (now_ms ())
    (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF)
;;

let find_goal goals id = List.find_opt (fun goal -> String.equal goal.id id) goals

let replace_goal goals updated =
  List.map (fun goal -> if String.equal goal.id updated.id then updated else goal) goals
;;

let update_state config f =
  let lock_path = goals_path config in
  Coord.with_file_lock config lock_path (fun () ->
    let state = read_state config in
    let next_state = f state in
    write_state config next_state;
    next_state)
;;

let get_goal config ~goal_id =
  read_state config |> fun state -> find_goal state.goals goal_id
;;

let update_goal config ~goal_id f =
  let lock_path = goals_path config in
  Coord.with_file_lock config lock_path (fun () ->
    let state = read_state config in
    match find_goal state.goals goal_id with
    | None -> Error "goal not found"
    | Some goal ->
      let now = Types.now_iso () in
      let updated_goal = normalize_goal (f { goal with updated_at = now }) in
      let next_state =
        { version = state.version + 1
        ; updated_at = now
        ; goals = replace_goal state.goals updated_goal
        }
      in
      write_state config next_state;
      Ok updated_goal)
;;

let delete_goal config ~goal_id =
  let before = read_state config in
  if not (List.exists (fun goal -> String.equal goal.id goal_id) before.goals)
  then Error "Goal not found"
  else (
    ignore
      (update_state config (fun state ->
         { version = state.version + 1
         ; goals =
             List.filter (fun goal -> not (String.equal goal.id goal_id)) state.goals
         ; updated_at = Types.now_iso ()
         }));
    Ok ())
;;

let sort_goals goals =
  let horizon_rank = function
    | Short -> 0
    | Mid -> 1
    | Long -> 2
  in
  List.sort
    (fun left right ->
       let by_horizon =
         compare (horizon_rank left.horizon) (horizon_rank right.horizon)
       in
       if by_horizon <> 0
       then by_horizon
       else (
         let by_priority = compare left.priority right.priority in
         if by_priority <> 0
         then by_priority
         else String.compare right.updated_at left.updated_at))
    goals
;;

let list_goals config ?horizon ?status ?phase () =
  read_state config
  |> fun state ->
  state.goals
  |> List.filter (fun goal ->
    match horizon with
    | None -> true
    | Some horizon -> goal.horizon = horizon)
  |> List.filter (fun goal ->
    match status with
    | None -> true
    | Some status -> goal.status = status)
  |> List.filter (fun goal ->
    match phase with
    | None -> true
    | Some phase -> goal.phase = phase)
  |> sort_goals
;;

let upsert_goal
      config
      ?id
      ?horizon
      ?title
      ?metric
      ?target_value
      ?due_date
      ?priority
      ?status
      ?phase
      ?parent_goal_id
      ?verifier_policy
      ?require_completion_approval
      ()
  =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "")
  then Error "title required for new goal"
  else (
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
      let now = Types.now_iso () in
      let resolved_id = Option.value id ~default:(gen_goal_id ()) in
      let was_created = ref false in
      let state =
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
                { existing with
                  horizon = Option.value horizon ~default:existing.horizon
                ; title = Option.value title ~default:existing.title
                ; metric =
                    (match metric with
                     | Some _ -> metric
                     | None -> existing.metric)
                ; target_value =
                    (match target_value with
                     | Some _ -> target_value
                     | None -> existing.target_value)
                ; due_date =
                    (match due_date with
                     | Some _ -> due_date
                     | None -> existing.due_date)
                ; priority =
                    clamp_priority (Option.value priority ~default:existing.priority)
                ; status = goal_status_of_phase next_phase
                ; phase = next_phase
                ; verifier_policy =
                    (match verifier_policy with
                     | Some _ -> verifier_policy
                     | None -> existing.verifier_policy)
                ; require_completion_approval =
                    (match require_completion_approval with
                     | Some value -> value
                     | None -> existing.require_completion_approval)
                ; active_verification_request_id = existing.active_verification_request_id
                ; parent_goal_id =
                    (match parent_goal_id with
                     | Some _ -> parent_goal_id
                     | None -> existing.parent_goal_id)
                ; updated_at = now
                }
            in
            { version = state.version + 1
            ; updated_at = now
            ; goals = replace_goal state.goals next_goal
            }
          | None ->
            let new_goal =
              normalize_goal
                { id = resolved_id
                ; horizon = Option.value horizon ~default:Short
                ; title = Option.value title ~default:"Untitled goal"
                ; metric
                ; target_value
                ; due_date
                ; priority = clamp_priority (Option.value priority ~default:3)
                ; status = goal_status_of_phase default_phase
                ; phase = default_phase
                ; verifier_policy
                ; require_completion_approval =
                    Option.value require_completion_approval ~default:false
                ; active_verification_request_id = None
                ; parent_goal_id
                ; last_review_note = None
                ; last_review_at = None
                ; created_at = now
                ; updated_at = now
                }
            in
            was_created := true;
            { version = state.version + 1
            ; updated_at = now
            ; goals = state.goals @ [ new_goal ]
            })
      in
      (match find_goal state.goals resolved_id with
       | Some goal -> Ok (goal, if !was_created then `created else `updated)
       | None -> Error "failed to save goal"))
;;

let compute_rollup goals =
  let count predicate = List_util.count_if predicate goals in
  { short_count = count (fun goal -> goal.horizon = Short)
  ; mid_count = count (fun goal -> goal.horizon = Mid)
  ; long_count = count (fun goal -> goal.horizon = Long)
  ; active_count = count (fun goal -> goal.status = Active)
  ; paused_count = count (fun goal -> goal.status = Paused)
  ; done_count = count (fun goal -> goal.status = Done)
  ; dropped_count = count (fun goal -> goal.status = Dropped)
  }
;;

let snapshot config ~mode =
  ensure_dirs config;
  let state = read_state config in
  let snapshot_id = Printf.sprintf "gsnap-%d" (now_ms ()) in
  let snapshot =
    { snapshot_id
    ; created_at = Types.now_iso ()
    ; mode
    ; goals = state.goals
    ; rollup = compute_rollup state.goals
    }
  in
  let path = Filename.concat (snapshots_dir config) (snapshot_id ^ ".json") in
  Coord.write_json config path (snapshot_to_yojson snapshot);
  snapshot
;;

let parse_yyyy_mm_dd s =
  try
    Scanf.sscanf s "%d-%d-%d" (fun year month day ->
      let tm =
        { Unix.tm_sec = 0
        ; tm_min = 0
        ; tm_hour = 0
        ; tm_mday = day
        ; tm_mon = month - 1
        ; tm_year = year - 1900
        ; tm_wday = 0
        ; tm_yday = 0
        ; tm_isdst = false
        }
      in
      let local_epoch, _ = Unix.mktime tm in
      let utc_as_local, _ = Unix.mktime (Unix.gmtime local_epoch) in
      let tz_offset = local_epoch -. utc_as_local in
      Some (local_epoch +. tz_offset))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.warn "goal_store: parse_yyyy_mm_dd failed: %s" (Printexc.to_string exn);
    None
;;

let days_until due_date =
  match due_date with
  | None -> None
  | Some due_date ->
    (match parse_yyyy_mm_dd due_date with
     | None -> None
     | Some ts ->
       let diff = ts -. Unix.time () in
       Some (int_of_float (diff /. Masc_time_constants.day)))
;;

let should_refresh_goal mode goal =
  match mode with
  | Daily -> goal.horizon = Short && goal.phase = Goal_phase.Executing
  | Weekly -> goal.horizon = Mid && goal.phase = Goal_phase.Executing
  | Monthly -> goal.horizon = Long && goal.phase = Goal_phase.Executing
;;

let reprioritize mode goal =
  let next_priority =
    match days_until goal.due_date with
    | Some days when days < 0 -> 1
    | Some days when mode = Daily && days <= 3 -> max 1 (goal.priority - 1)
    | Some days when mode = Weekly && days <= 14 -> max 1 (goal.priority - 1)
    | Some days when mode = Monthly && days <= 45 -> max 1 (goal.priority - 1)
    | _ -> goal.priority
  in
  if next_priority = goal.priority
  then goal, false
  else
    ( { goal with priority = next_priority; updated_at = Types.now_iso () }
      |> normalize_goal
    , true )
;;

let refresh config ~mode =
  let scanned = ref 0 in
  let updated = ref 0 in
  ignore
    (update_state config (fun state ->
       let goals =
         List.map
           (fun goal ->
              if should_refresh_goal mode goal
              then (
                incr scanned;
                let goal, changed = reprioritize mode goal in
                if changed then incr updated;
                goal)
              else goal)
           state.goals
       in
       { version = state.version + 1; updated_at = Types.now_iso (); goals }));
  let snapshot = snapshot config ~mode:(snapshot_mode_of_refresh_mode mode) in
  { mode; scanned = !scanned; updated = !updated; snapshot_id = snapshot.snapshot_id }
;;

let review_goal config ~goal_id ~(outcome : review_outcome) ?new_horizon ?note () =
  let now = Types.now_iso () in
  update_goal config ~goal_id (fun goal ->
    let phase, priority =
      match outcome with
      | ReviewDone -> Goal_phase.Completed, goal.priority
      | ReviewProgress -> Goal_phase.Executing, max 1 (goal.priority - 1)
      | ReviewBlocked -> Goal_phase.Blocked, min 5 (goal.priority + 1)
      | ReviewDropped -> Goal_phase.Dropped, goal.priority
    in
    { goal with
      phase
    ; status = goal_status_of_phase phase
    ; priority
    ; horizon = Option.value new_horizon ~default:goal.horizon
    ; last_review_note = note
    ; last_review_at = Some now
    ; active_verification_request_id =
        (match phase with
         | Goal_phase.Awaiting_verification -> goal.active_verification_request_id
         | _ -> None)
    ; updated_at = now
    })
;;

let active_goals config = list_goals config ~status:Active ()
let has_scheduler_state config = Coord.path_exists config (scheduler_state_path config)
