(* Variant types for domain values — Parse, Don't Validate.
   Custom yojson serializers maintain backward-compatible JSON ("active", "short", etc.). *)

type goal_status = Active | Paused | Done | Dropped

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

type horizon = Short | Mid | Long

let horizon_to_yojson = function
  | Short -> `String "short"
  | Mid -> `String "mid"
  | Long -> `String "long"

let horizon_of_yojson = function
  | `String "short" -> Ok Short
  | `String "mid" -> Ok Mid
  | `String "long" -> Ok Long
  | j -> Error ("horizon_of_yojson: " ^ Yojson.Safe.to_string j)

type refresh_mode = Daily | Weekly | Monthly

let refresh_mode_to_yojson = function
  | Daily -> `String "daily"
  | Weekly -> `String "weekly"
  | Monthly -> `String "monthly"

let refresh_mode_of_yojson = function
  | `String "daily" -> Ok Daily
  | `String "weekly" -> Ok Weekly
  | `String "monthly" -> Ok Monthly
  | j -> Error ("refresh_mode_of_yojson: " ^ Yojson.Safe.to_string j)

type snapshot_mode = SnapDaily | SnapWeekly | SnapMonthly | SnapManual

let snapshot_mode_to_yojson = function
  | SnapDaily -> `String "daily"
  | SnapWeekly -> `String "weekly"
  | SnapMonthly -> `String "monthly"
  | SnapManual -> `String "manual"

let snapshot_mode_of_yojson = function
  | `String "daily" -> Ok SnapDaily
  | `String "weekly" -> Ok SnapWeekly
  | `String "monthly" -> Ok SnapMonthly
  | `String "manual" -> Ok SnapManual
  | j -> Error ("snapshot_mode_of_yojson: " ^ Yojson.Safe.to_string j)

let snapshot_mode_of_refresh_mode = function
  | Daily -> SnapDaily
  | Weekly -> SnapWeekly
  | Monthly -> SnapMonthly

let parse_snapshot_mode s =
  match String.trim s |> String.lowercase_ascii with
  | "daily" -> Some SnapDaily
  | "weekly" -> Some SnapWeekly
  | "monthly" -> Some SnapMonthly
  | "manual" -> Some SnapManual
  | _ -> None

type review_outcome = ReviewDone | ReviewProgress | ReviewBlocked | ReviewDropped

let review_outcome_to_yojson = function
  | ReviewDone -> `String "done"
  | ReviewProgress -> `String "progress"
  | ReviewBlocked -> `String "blocked"
  | ReviewDropped -> `String "dropped"

let review_outcome_of_yojson = function
  | `String "done" -> Ok ReviewDone
  | `String "progress" -> Ok ReviewProgress
  | `String "blocked" -> Ok ReviewBlocked
  | `String "dropped" -> Ok ReviewDropped
  | j -> Error ("review_outcome_of_yojson: " ^ Yojson.Safe.to_string j)

(* Record types *)

type goal = {
  id : string;
  horizon : horizon;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  status : goal_status;
  parent_goal_id : string option;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string;
  updated_at : string;
}
[@@deriving yojson]

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
}
[@@deriving yojson]

type rollup = {
  short_count : int;
  mid_count : int;
  long_count : int;
  active_count : int;
  paused_count : int;
  done_count : int;
  dropped_count : int;
}
[@@deriving yojson]

type snapshot = {
  snapshot_id : string;
  created_at : string;
  mode : snapshot_mode;
  goals : goal list;
  rollup : rollup;
}
[@@deriving yojson]

type upsert_kind = [ `created | `updated ]

type refresh_result = {
  mode : refresh_mode;
  scanned : int;
  updated : int;
  snapshot_id : string;
}
[@@deriving yojson]

(* Parsing: string -> variant at the boundary *)

let normalize_lower s =
  String.trim s |> String.lowercase_ascii

let parse_horizon = function
  | Some s -> (
      match normalize_lower s with
      | "short" -> Some Short
      | "mid" -> Some Mid
      | "long" -> Some Long
      | _ -> None)
  | None -> None

let parse_goal_status = function
  | Some s -> (
      match normalize_lower s with
      | "active" -> Some Active
      | "paused" -> Some Paused
      | "done" -> Some Done
      | "dropped" -> Some Dropped
      | _ -> None)
  | None -> None

let parse_refresh_mode s =
  match normalize_lower s with
  | "daily" -> Some Daily
  | "weekly" -> Some Weekly
  | "monthly" -> Some Monthly
  | _ -> None

let parse_review_outcome s =
  match normalize_lower s with
  | "done" -> Some ReviewDone
  | "progress" -> Some ReviewProgress
  | "blocked" -> Some ReviewBlocked
  | "dropped" -> Some ReviewDropped
  | _ -> None

let clamp_priority p = max 1 (min 5 p)

let goals_path config =
  Filename.concat (Room.masc_dir config) "goals.json"

let snapshots_dir config =
  Filename.concat (Room.masc_dir config) "goals_snapshots"

let scheduler_state_path config =
  Filename.concat (Room.masc_dir config) "goals_scheduler_state.json"

let ensure_dirs config =
  Room.mkdir_p (Room.masc_dir config);
  Room.mkdir_p (snapshots_dir config);
  ()

let default_state () =
  { version = 1; updated_at = Types.now_iso (); goals = [] }

let read_state config =
  ensure_dirs config;
  let path = goals_path config in
  if Room.path_exists config path then
    let json = Room.read_json config path in
    match state_of_yojson json with
    | Ok s -> s
    | Error _ -> default_state ()
  else
    default_state ()

let write_state config st =
  ensure_dirs config;
  Room.write_json config (goals_path config) (state_to_yojson st)

let now_ms () =
  int_of_float (Time_compat.now () *. 1000.0)

let gen_goal_id () =
  Printf.sprintf "goal-%d-%04x" (now_ms ()) (Hashtbl.hash (Unix.gettimeofday ()) land 0xFFFF)

let find_goal goals id =
  List.find_opt (fun g -> g.id = id) goals

let replace_goal goals updated =
  List.map (fun g -> if g.id = updated.id then updated else g) goals

let update_state config f =
  let lock_path = goals_path config in
  Room.with_file_lock config lock_path (fun () ->
    let st = read_state config in
    let st' = f st in
    write_state config st';
    st')

let delete_goal config ~goal_id =
  let before = read_state config in
  if not (List.exists (fun g -> g.id = goal_id) before.goals) then
    Error "Goal not found"
  else begin
    ignore (update_state config (fun st ->
      { st with
        goals = List.filter (fun g -> g.id <> goal_id) st.goals;
        updated_at = Types.now_iso () }));
    Ok ()
  end

let sort_goals goals =
  let horizon_rank = function
    | Short -> 0
    | Mid -> 1
    | Long -> 2
  in
  List.sort
    (fun a b ->
      let by_horizon = compare (horizon_rank a.horizon) (horizon_rank b.horizon) in
      if by_horizon <> 0 then by_horizon
      else
        let by_prio = compare a.priority b.priority in
        if by_prio <> 0 then by_prio
        else String.compare b.updated_at a.updated_at)
    goals

let list_goals config ?horizon ?status () =
  let st = read_state config in
  st.goals
  |> List.filter (fun g ->
         match horizon with
         | None -> true
         | Some h -> g.horizon = h)
  |> List.filter (fun g ->
         match status with
         | None -> true
         | Some s -> g.status = s)
  |> sort_goals

let upsert_goal config ?id ?horizon ?title ?metric ?target_value ?due_date
    ?priority ?status ?parent_goal_id () =
  let is_new_goal = id = None in
  if is_new_goal && (title = None || title = Some "") then
    Error "title required for new goal"
  else
    let now = Types.now_iso () in
    let resolved_id = Option.value id ~default:(gen_goal_id ()) in
    let was_created = ref false in
    let updated_goal =
      update_state config (fun st ->
          match find_goal st.goals resolved_id with
          | Some existing ->
              let next_goal =
                {
                  existing with
                  horizon =
                    Option.value horizon ~default:existing.horizon;
                  title = Option.value title ~default:existing.title;
                  metric = (match metric with Some _ -> metric | None -> existing.metric);
                  target_value =
                    (match target_value with
                    | Some _ -> target_value
                    | None -> existing.target_value);
                  due_date =
                    (match due_date with Some _ -> due_date | None -> existing.due_date);
                  priority =
                    clamp_priority
                      (Option.value priority ~default:existing.priority);
                  status = Option.value status ~default:existing.status;
                  parent_goal_id =
                    (match parent_goal_id with
                    | Some _ -> parent_goal_id
                    | None -> existing.parent_goal_id);
                  updated_at = now;
                }
              in
              {
                version = st.version + 1;
                updated_at = now;
                goals = replace_goal st.goals next_goal;
              }
          | None ->
              let new_goal =
                {
                  id = resolved_id;
                  horizon = Option.value horizon ~default:Short;
                  title = Option.value title ~default:"Untitled goal";
                  metric;
                  target_value;
                  due_date;
                  priority =
                    clamp_priority (Option.value priority ~default:3);
                  status = Option.value status ~default:Active;
                  parent_goal_id;
                  last_review_note = None;
                  last_review_at = None;
                  created_at = now;
                  updated_at = now;
                }
              in
              was_created := true;
              {
                version = st.version + 1;
                updated_at = now;
                goals = st.goals @ [ new_goal ];
              })
    in
    let saved = find_goal updated_goal.goals resolved_id in
    match saved with
    | Some g ->
        Ok (g, if !was_created then `created else `updated)
    | None -> Error "failed to save goal"

let compute_rollup goals =
  let count p = List.length (List.filter p goals) in
  {
    short_count = count (fun g -> g.horizon = Short);
    mid_count = count (fun g -> g.horizon = Mid);
    long_count = count (fun g -> g.horizon = Long);
    active_count = count (fun g -> g.status = Active);
    paused_count = count (fun g -> g.status = Paused);
    done_count = count (fun g -> g.status = Done);
    dropped_count = count (fun g -> g.status = Dropped);
  }

let snapshot config ~mode =
  ensure_dirs config;
  let st = read_state config in
  let snapshot_id = Printf.sprintf "gsnap-%d" (now_ms ()) in
  let snap =
    {
      snapshot_id;
      created_at = Types.now_iso ();
      mode;
      goals = st.goals;
      rollup = compute_rollup st.goals;
    }
  in
  let path =
    Filename.concat (snapshots_dir config) (snapshot_id ^ ".json")
  in
  Room.write_json config path (snapshot_to_yojson snap);
  snap

let parse_yyyy_mm_dd s =
  try
    Scanf.sscanf s "%d-%d-%d" (fun year month day ->
        let tm =
          {
            Unix.tm_sec = 0;
            tm_min = 0;
            tm_hour = 0;
            tm_mday = day;
            tm_mon = month - 1;
            tm_year = year - 1900;
            tm_wday = 0;
            tm_yday = 0;
            tm_isdst = false;
          }
        in
        let local_epoch, _ = Unix.mktime tm in
        let utc_as_local, _ = Unix.mktime (Unix.gmtime local_epoch) in
        let tz_offset = local_epoch -. utc_as_local in
        Some (local_epoch +. tz_offset))
  with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
    Log.Misc.warn "goal_store: parse_yyyy_mm_dd failed: %s" (Printexc.to_string exn);
    None

let days_until due_date =
  match due_date with
  | None -> None
  | Some d -> (
      match parse_yyyy_mm_dd d with
      | None -> None
      | Some ts ->
          let diff = ts -. Unix.time () in
          Some (int_of_float (diff /. Masc_time_constants.day)))

let should_refresh_goal mode goal =
  match mode with
  | Daily -> goal.horizon = Short && goal.status = Active
  | Weekly -> goal.horizon = Mid && goal.status = Active
  | Monthly -> goal.horizon = Long && goal.status = Active

let reprioritize mode goal =
  let next_priority =
    match days_until goal.due_date with
    | Some d when d < 0 -> 1
    | Some d when mode = Daily && d <= 3 -> max 1 (goal.priority - 1)
    | Some d when mode = Weekly && d <= 14 -> max 1 (goal.priority - 1)
    | Some d when mode = Monthly && d <= 45 -> max 1 (goal.priority - 1)
    | _ -> goal.priority
  in
  if next_priority = goal.priority then
    (goal, false)
  else
    ({ goal with priority = next_priority; updated_at = Types.now_iso () }, true)

let refresh config ~mode =
  let scanned = ref 0 in
  let updated = ref 0 in
  ignore
    (update_state config (fun st ->
         let goals =
           List.map
             (fun g ->
               if should_refresh_goal mode g then (
                 incr scanned;
                 let g', changed = reprioritize mode g in
                 if changed then incr updated;
                 g')
               else g)
             st.goals
         in
         { version = st.version + 1; updated_at = Types.now_iso (); goals }));
  let snap = snapshot config ~mode:(snapshot_mode_of_refresh_mode mode) in
  { mode; scanned = !scanned; updated = !updated; snapshot_id = snap.snapshot_id }

let review_goal config ~goal_id ~(outcome : review_outcome) ?new_horizon ?note () =
  let now = Types.now_iso () in
  let found = ref false in
  let st =
    update_state config (fun state ->
        let goals =
          List.map
            (fun g ->
              if g.id <> goal_id then g
              else (
                found := true;
                let status, priority =
                  match outcome with
                  | ReviewDone -> (Done, g.priority)
                  | ReviewProgress -> (Active, max 1 (g.priority - 1))
                  | ReviewBlocked -> (Paused, min 5 (g.priority + 1))
                  | ReviewDropped -> (Dropped, g.priority)
                in
                {
                  g with
                  status;
                  priority;
                  horizon = Option.value new_horizon ~default:g.horizon;
                  last_review_note = note;
                  last_review_at = Some now;
                  updated_at = now;
                }))
            state.goals
        in
        { version = state.version + 1; updated_at = now; goals })
  in
  if not !found then Error "goal not found"
  else
    match find_goal st.goals goal_id with
    | Some g -> Ok g
    | None -> Error "goal not found after review"

let active_goals config =
  list_goals config ~status:Active ()

let has_scheduler_state config =
  Room.path_exists config (scheduler_state_path config)
