type goal = {
  id : string;
  horizon : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  status : string;
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
  mode : string;
  goals : goal list;
  rollup : rollup;
}
[@@deriving yojson]

type upsert_kind = [ `created | `updated ]

type refresh_result = {
  mode : string;
  scanned : int;
  updated : int;
  snapshot_id : string;
}
[@@deriving yojson]

let horizons = [ "short"; "mid"; "long" ]
let statuses = [ "active"; "paused"; "done"; "dropped" ]

let normalize_lower s =
  String.trim s |> String.lowercase_ascii

let normalize_horizon = function
  | Some s ->
      let v = normalize_lower s in
      if List.mem v horizons then Some v else None
  | None -> None

let normalize_status = function
  | Some s ->
      let v = normalize_lower s in
      if List.mem v statuses then Some v else None
  | None -> None

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
  Printf.sprintf "goal-%d-%04x" (now_ms ()) (Random.int 0x10000)

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

let sort_goals goals =
  let horizon_rank = function
    | "short" -> 0
    | "mid" -> 1
    | "long" -> 2
    | _ -> 3
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
  let normalized_horizon = normalize_horizon horizon in
  let normalized_status = normalize_status status in
  match horizon with
  | Some _ when normalized_horizon = None -> Error "invalid horizon (short|mid|long)"
  | _ -> (
      match status with
      | Some _ when normalized_status = None ->
          Error "invalid status (active|paused|done|dropped)"
      | _ ->
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
                          Option.value normalized_horizon ~default:existing.horizon;
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
                        status = Option.value normalized_status ~default:existing.status;
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
                    let horizon_value =
                      Option.value normalized_horizon ~default:"short"
                    in
                    let title_value = Option.value title ~default:"Untitled goal" in
                    let new_goal =
                      {
                        id = resolved_id;
                        horizon = horizon_value;
                        title = title_value;
                        metric;
                        target_value;
                        due_date;
                        priority =
                          clamp_priority (Option.value priority ~default:3);
                        status = Option.value normalized_status ~default:"active";
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
          | None -> Error "failed to save goal")

let compute_rollup goals =
  let count p = List.length (List.filter p goals) in
  {
    short_count = count (fun g -> g.horizon = "short");
    mid_count = count (fun g -> g.horizon = "mid");
    long_count = count (fun g -> g.horizon = "long");
    active_count = count (fun g -> g.status = "active");
    paused_count = count (fun g -> g.status = "paused");
    done_count = count (fun g -> g.status = "done");
    dropped_count = count (fun g -> g.status = "dropped");
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
        let ts, _ = Unix.mktime tm in
        Some ts)
  with exn ->
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
          Some (int_of_float (diff /. 86400.0)))

let should_refresh_goal mode goal =
  match mode with
  | "daily" -> goal.horizon = "short" && goal.status = "active"
  | "weekly" -> goal.horizon = "mid" && goal.status = "active"
  | "monthly" -> goal.horizon = "long" && goal.status = "active"
  | _ -> false

let reprioritize mode goal =
  let next_priority =
    match days_until goal.due_date with
    | Some d when d < 0 -> 1
    | Some d when mode = "daily" && d <= 3 -> max 1 (goal.priority - 1)
    | Some d when mode = "weekly" && d <= 14 -> max 1 (goal.priority - 1)
    | Some d when mode = "monthly" && d <= 45 -> max 1 (goal.priority - 1)
    | _ -> goal.priority
  in
  if next_priority = goal.priority then
    (goal, false)
  else
    ({ goal with priority = next_priority; updated_at = Types.now_iso () }, true)

let refresh config ~mode =
  let mode = normalize_lower mode in
  if not (List.mem mode [ "daily"; "weekly"; "monthly" ]) then
    Error "mode must be daily|weekly|monthly"
  else
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
    let snap = snapshot config ~mode in
    Ok { mode; scanned = !scanned; updated = !updated; snapshot_id = snap.snapshot_id }

let review_goal config ~goal_id ~outcome ?new_horizon ?note () =
  let outcome = normalize_lower outcome in
  let normalized_horizon = normalize_horizon new_horizon in
  match new_horizon with
  | Some _ when normalized_horizon = None ->
      Error "invalid new_horizon (short|mid|long)"
  | _ ->
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
                      | "done" -> ("done", g.priority)
                      | "progress" -> ("active", max 1 (g.priority - 1))
                      | "blocked" -> ("paused", min 5 (g.priority + 1))
                      | "dropped" -> ("dropped", g.priority)
                      | _ -> (g.status, g.priority)
                    in
                    {
                      g with
                      status;
                      priority;
                      horizon = Option.value normalized_horizon ~default:g.horizon;
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
  list_goals config ~status:"active" ()

let has_scheduler_state config =
  Room.path_exists config (scheduler_state_path config)
