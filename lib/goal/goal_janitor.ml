(** Goal_janitor — Periodic cleanup of stale and dropped goals.

    Four sweep rules:
    1. Purge: delete Dropped goals older than [dropped_ttl_days].
    2. Stagnate: mark Active goals with no update for [stagnant_days] as Dropped.
    3. Orphan: remove active_goal_ids from keeper_meta that reference
       non-existent goals in the Goal Store.
    4. Escalate: report stale unclaimed tasks that have no goal linkage.

    @since 2.236.0 *)

type sweep_config = {
  dropped_ttl_days : int;  (** Delete Dropped goals after this many days. Default 7. *)
  stagnant_days : int;     (** Drop Active goals with no update after this many days. Default 30. *)
  orphan_task_escalation_age_seconds : int;
      (** Report unclaimed tasks without goal linkage after this age. Default 30 min. *)
}

let default_config = {
  dropped_ttl_days = 7;
  stagnant_days = 30;
  orphan_task_escalation_age_seconds = 30 * 60;
}

type sweep_result = {
  purged : int;     (** Dropped goals deleted *)
  stagnated : int;  (** Active goals marked Dropped *)
  orphans : int;    (** Orphaned active_goal_ids cleaned *)
  orphan_tasks : int;  (** Stale unclaimed tasks missing goal linkage *)
}

let sweep_result_to_yojson r =
  `Assoc [
    ("purged", `Int r.purged);
    ("stagnated", `Int r.stagnated);
    ("orphans", `Int r.orphans);
    ("orphan_tasks", `Int r.orphan_tasks);
  ]

(** Parse ISO 8601 timestamp to Unix epoch seconds. *)
let parse_iso_ts s =
  Masc_domain.parse_iso8601_opt s

let days_since_update (goal : Goal_store.goal) ~now =
  match parse_iso_ts goal.updated_at with
  | Some ts -> Some (int_of_float ((now -. ts) /. Masc_time_constants.day))
  | None -> None

(** Sweep goals: purge old Dropped, stagnate old Active.
    Returns (updated_goals, sweep_result). Does NOT write state. *)
let sweep_goals ~(config : sweep_config) (goals : Goal_store.goal list)
  : Goal_store.goal list * sweep_result =
  let now = Unix.gettimeofday () in
  let iso_now = Masc_domain.now_iso () in
  let purged = ref 0 in
  let stagnated = ref 0 in
  let result =
    goals |> List.filter_map (fun (g : Goal_store.goal) ->
      let age = days_since_update g ~now in
      match g.phase, age with
      | Goal_phase.Dropped, Some d when d >= config.dropped_ttl_days ->
        incr purged;
        Log.Misc.info "[GoalJanitor] purge: %s (%s, dropped %d days ago)"
          g.id g.title d;
        None
      | Goal_phase.Executing, Some d when d >= config.stagnant_days ->
        incr stagnated;
        Log.Misc.info "[GoalJanitor] stagnate: %s (%s, no update for %d days)"
          g.id g.title d;
        Some { g with
               phase = Goal_phase.Dropped;
               status = Goal_store.Dropped;
               last_review_note = Some (Printf.sprintf "auto-dropped: no update for %d days" d);
               last_review_at = Some iso_now;
               updated_at = iso_now }
      | _ -> Some g)
  in
  (result, { purged = !purged; stagnated = !stagnated; orphans = 0;
             orphan_tasks = 0 })

let task_age_seconds ?(now = Unix.gettimeofday ()) (task : Masc_domain.task) =
  match parse_iso_ts task.created_at with
  | None -> None
  | Some created_at -> Some (int_of_float (max 0.0 (now -. created_at)))

let task_has_current_goal_link ~valid_goal_ids (task : Masc_domain.task) =
  match task.goal_id with
  | Some goal_id -> List.mem goal_id valid_goal_ids
  | None ->
      List.exists
        (fun goal_id -> Convergence.task_matches_goal ~goal_id task)
        valid_goal_ids

let audit_unclaimed_goal_orphan_tasks ?(now = Unix.gettimeofday ())
    ~valid_goal_ids ~min_age_seconds (tasks : Masc_domain.task list) =
  tasks
  |> List.filter_map (fun (task : Masc_domain.task) ->
    match task.task_status, task.goal_id, task_age_seconds ~now task with
    | Masc_domain.Todo, None, Some age_seconds
      when age_seconds >= min_age_seconds
           && not (task_has_current_goal_link ~valid_goal_ids task) ->
        Some (task, age_seconds)
    | _ -> None)

let emit_orphan_task_escalation room_config ~threshold_seconds orphan_tasks =
  match orphan_tasks with
  | [] -> ()
  | _ ->
      let task_ids =
        List.map
          (fun ((task, _) : Masc_domain.task * int) -> `String task.id)
          orphan_tasks
      in
      let task_items =
        List.map
          (fun ((task, age_seconds) : Masc_domain.task * int) ->
             `Assoc
               [ ("task_id", `String task.id)
               ; ("title", `String task.title)
               ; ("created_at", `String task.created_at)
               ; ("age_seconds", `Int age_seconds)
               ; ("created_by", Json_util.string_opt_to_json task.created_by)
               ])
          orphan_tasks
      in
      Coord.log_event room_config
        (`Assoc
           [ ("type", `String "goal_orphan_task_escalation")
           ; ("subsystem", `String "goal_janitor")
           ; ("threshold_seconds", `Int threshold_seconds)
           ; ("orphan_task_count", `Int (List.length orphan_tasks))
           ; ("task_ids", `List task_ids)
           ; ("tasks", `List task_items)
           ; ( "action",
               `String "link_task_goal_id_or_cancel_stale_unclaimed_task" )
           ; ("ts", `String (Masc_domain.now_iso ()))
           ]);
      Log.Misc.warn
        "[GoalJanitor] escalated %d stale unclaimed task(s) without goal linkage"
        (List.length orphan_tasks)

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
let run ?(config = default_config) (room_config : Coord.config) : sweep_result =
  let st = Goal_store.read_state room_config in
  let goals', partial = sweep_goals ~config st.goals in
  let valid_ids = List.map (fun (g : Goal_store.goal) -> g.id) goals' in
  (* Write updated goal state *)
  if partial.purged > 0 || partial.stagnated > 0 then begin
    Goal_store.write_state room_config
      { goals = goals';
        version = st.version + 1;
        updated_at = Masc_domain.now_iso () }
  end;
  (* Prune active_goal_ids from all keeper metas *)
  let total_orphans = ref 0 in
  let keeper_dir =
    Filename.concat (Coord.masc_dir room_config) "keepers"
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
            let updated = { meta with active_goal_ids = pruned_ids } in
            match Keeper_types.write_meta room_config updated with
            | Ok () ->
                total_orphans := !total_orphans + removed
            | Error e ->
                Log.Misc.warn
                  "[GoalJanitor] failed to persist orphan-pruned meta for \
                   keeper=%s removed=%d: %s"
                  name removed e
          end
        | Ok None | Ok (Some _) | Error _ -> ()
      end);
  let orphan_task_rows =
    Coord.get_tasks_safe room_config
    |> audit_unclaimed_goal_orphan_tasks ~valid_goal_ids:valid_ids
         ~min_age_seconds:config.orphan_task_escalation_age_seconds
  in
  emit_orphan_task_escalation room_config
    ~threshold_seconds:config.orphan_task_escalation_age_seconds
    orphan_task_rows;
  let result = { partial with orphans = !total_orphans;
                              orphan_tasks = List.length orphan_task_rows } in
  if result.purged > 0 || result.stagnated > 0 || result.orphans > 0
     || result.orphan_tasks > 0 then
    Log.Misc.info
      "[GoalJanitor] sweep done: purged=%d stagnated=%d orphans=%d \
       orphan_tasks=%d"
      result.purged result.stagnated result.orphans result.orphan_tasks;
  result
