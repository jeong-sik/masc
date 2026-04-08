(** Goal_janitor — Periodic cleanup of stale and dropped goals.

    Three sweep rules:
    1. Purge: delete Dropped goals older than [dropped_ttl_days].
    2. Stagnate: mark Active goals with no update for [stagnant_days] as Dropped.
    3. Orphan: remove active_goal_ids from keeper_meta that reference
       non-existent goals in the Goal Store.

    @since 2.236.0 *)

type sweep_config = {
  dropped_ttl_days : int;  (** Delete Dropped goals after this many days. Default 7. *)
  stagnant_days : int;     (** Drop Active goals with no update after this many days. Default 30. *)
}

let default_config = {
  dropped_ttl_days = 7;
  stagnant_days = 30;
}

type sweep_result = {
  purged : int;     (** Dropped goals deleted *)
  stagnated : int;  (** Active goals marked Dropped *)
  orphans : int;    (** Orphaned active_goal_ids cleaned *)
}

let sweep_result_to_yojson r =
  `Assoc [
    ("purged", `Int r.purged);
    ("stagnated", `Int r.stagnated);
    ("orphans", `Int r.orphans);
  ]

(** Parse ISO 8601 timestamp to Unix epoch seconds. *)
let parse_iso_ts s =
  try
    Scanf.sscanf s "%d-%d-%dT%d:%d:%d" (fun y mo d h mi se ->
      let tm = {
        Unix.tm_sec = se; tm_min = mi; tm_hour = h;
        tm_mday = d; tm_mon = mo - 1; tm_year = y - 1900;
        tm_wday = 0; tm_yday = 0; tm_isdst = false;
      } in
      let epoch, _ = Unix.mktime tm in
      Some epoch)
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> None

let days_since_update (goal : Goal_store.goal) ~now =
  match parse_iso_ts goal.updated_at with
  | Some ts -> Some (int_of_float ((now -. ts) /. Masc_time_constants.day))
  | None -> None

(** Sweep goals: purge old Dropped, stagnate old Active.
    Returns (updated_goals, sweep_result). Does NOT write state. *)
let sweep_goals ~(config : sweep_config) (goals : Goal_store.goal list)
  : Goal_store.goal list * sweep_result =
  let now = Unix.gettimeofday () in
  let iso_now = Types.now_iso () in
  let purged = ref 0 in
  let stagnated = ref 0 in
  let result =
    goals |> List.filter_map (fun (g : Goal_store.goal) ->
      let age = days_since_update g ~now in
      match g.status, age with
      | Goal_store.Dropped, Some d when d >= config.dropped_ttl_days ->
        incr purged;
        Log.Misc.info "[GoalJanitor] purge: %s (%s, dropped %d days ago)"
          g.id g.title d;
        None
      | Goal_store.Active, Some d when d >= config.stagnant_days ->
        incr stagnated;
        Log.Misc.info "[GoalJanitor] stagnate: %s (%s, no update for %d days)"
          g.id g.title d;
        Some { g with
               status = Goal_store.Dropped;
               last_review_note = Some (Printf.sprintf "auto-dropped: no update for %d days" d);
               last_review_at = Some iso_now;
               updated_at = iso_now }
      | _ -> Some g)
  in
  (result, { purged = !purged; stagnated = !stagnated; orphans = 0 })

(** Clean orphaned active_goal_ids from keeper meta.
    Returns the pruned list and count of removed IDs. *)
let prune_active_goal_ids ~(valid_goal_ids : string list)
    (active_ids : string list) : string list * int =
  let before = List.length active_ids in
  let pruned =
    List.filter (fun id -> List.mem id valid_goal_ids) active_ids
  in
  let removed = before - List.length pruned in
  if removed > 0 then
    Log.Misc.info "[GoalJanitor] pruned %d orphaned active_goal_ids" removed;
  (pruned, removed)

(** Run a full sweep: goals + keeper active_goal_ids.
    Writes updated state to disk. *)
let run ?(config = default_config) (room_config : Room.config) : sweep_result =
  let st = Goal_store.read_state room_config in
  let goals', partial = sweep_goals ~config st.goals in
  let valid_ids = List.map (fun (g : Goal_store.goal) -> g.id) goals' in
  (* Write updated goal state *)
  if partial.purged > 0 || partial.stagnated > 0 then begin
    Goal_store.write_state room_config
      { goals = goals';
        version = st.version + 1;
        updated_at = Types.now_iso () }
  end;
  (* Prune active_goal_ids from all keeper metas *)
  let total_orphans = ref 0 in
  let keeper_dir =
    Filename.concat (Room.masc_dir room_config) "keepers"
  in
  if Sys.file_exists keeper_dir && Sys.is_directory keeper_dir then
    Sys.readdir keeper_dir
    |> Array.iter (fun entry ->
      if Filename.check_suffix entry ".json" then begin
        let name = Filename.chop_suffix entry ".json" in
        match Keeper_types.read_meta room_config name with
        | Ok (Some meta) when meta.active_goal_ids <> [] ->
          let pruned_ids, removed =
            prune_active_goal_ids ~valid_goal_ids:valid_ids meta.active_goal_ids
          in
          if removed > 0 then begin
            total_orphans := !total_orphans + removed;
            let updated = { meta with active_goal_ids = pruned_ids } in
            ignore (Keeper_types.write_meta room_config updated)
          end
        | _ -> ()
      end);
  let result = { partial with orphans = !total_orphans } in
  if result.purged > 0 || result.stagnated > 0 || result.orphans > 0 then
    Log.Misc.info "[GoalJanitor] sweep done: purged=%d stagnated=%d orphans=%d"
      result.purged result.stagnated result.orphans;
  result
