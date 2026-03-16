(** Room GC - Heartbeat, Zombie Cleanup, and Garbage Collection.

    Extracted from room.ml for modularity.
    Contains: heartbeat_in_room, heartbeat, cleanup_zombies, gc. *)

open Types
open Room_utils
open Room_state

(** Callback for force_release_task_r — set by Room after include.
    This avoids a circular dependency: force_release_task_r is defined
    in room.ml (task management section) and uses deeper task logic. *)
let force_release_task_fn
  : (config -> agent_name:string -> task_id:string -> unit -> string masc_result) ref
  = ref (fun _config ~agent_name:_ ~task_id:_ () ->
      Error (Types.TaskInvalidState "Room_gc: force_release_task_fn not connected"))

(** CP cleanup result type — mirrors Cp_cleanup.cleanup_result without
    introducing a dependency on Cp_cleanup (which depends on Room). *)
type cp_cleanup_result = {
  dead_units_removed : int;
  orphaned_units_removed : int;
  operations_archived : int;
  detachments_removed : int;
  intents_removed : int;
}

let empty_cp_result = {
  dead_units_removed = 0;
  orphaned_units_removed = 0;
  operations_archived = 0;
  detachments_removed = 0;
  intents_removed = 0;
}

(** Callback for CP cleanup — set by the module that connects Room_gc
    and Cp_cleanup (e.g. command_plane_v2.ml or room.ml post-include).
    This avoids a circular dependency: Cp_cleanup depends on Cp_io which
    depends on Room, and Room includes Room_gc. *)
let cp_cleanup_connected = ref false

let cp_cleanup_fn
  : (config -> cp_cleanup_result) ref
  = ref (fun _config -> empty_cp_result)


(** Update agent heartbeat - must be called periodically.
    Uses scoped config for room-specific heartbeat. *)
let heartbeat_in_room config ~room_id ~agent_name =
  let scoped = with_scope config (Named room_id) in
  ensure_room_bootstrap scoped room_id;
  let actual_name = resolve_agent_name config agent_name in
  let filename = safe_filename actual_name ^ ".json" in
  let agent_file = Filename.concat (agents_dir scoped) filename in
  if path_exists scoped agent_file then begin
    with_file_lock scoped agent_file (fun () ->
      let json = read_json scoped agent_file in
      match agent_of_yojson json with
      | Ok agent ->
          let updated = { agent with last_seen = now_iso () } in
          write_json scoped agent_file (agent_to_yojson updated);
          Printf.sprintf "💓 %s heartbeat updated in %s" actual_name room_id
      | Error _ ->
          Printf.sprintf "⚠ Invalid agent file for %s in %s" actual_name room_id
    )
  end else
    Printf.sprintf "⚠ Agent %s not found in %s" agent_name room_id

let heartbeat config ~agent_name =
  ensure_initialized config;
  let actual_name = resolve_agent_name config agent_name in
  let filename = safe_filename actual_name ^ ".json" in
  let agent_file = Filename.concat (agents_dir config) filename in
  if path_exists config agent_file then begin
    with_file_lock config agent_file (fun () ->
      let json = read_json config agent_file in
      match agent_of_yojson json with
      | Ok agent ->
          let updated = { agent with last_seen = now_iso () } in
          write_json config agent_file (agent_to_yojson updated);
          Printf.sprintf "💓 %s heartbeat updated" actual_name
      | Error _ ->
          Printf.sprintf "⚠ Invalid agent file for %s" actual_name
    )
  end else
    Printf.sprintf "⚠ Agent %s not found" agent_name

(** Cleanup zombie agents - removes stale agents *)
let is_keeper_runtime_agent_name = Resilience.Zombie.is_keeper_name

let cleanup_zombies config =
  ensure_initialized config;

  (* Single path: agents_dir derives from config.scope *)
  let agents_path = agents_dir config in
  let scan_paths =
    if Sys.file_exists agents_path then [ agents_path ] else []
  in
  if scan_paths = [] then
    "📋 No agents directory"
  else begin
    let zombies = ref [] in

    (* Find zombie agents across all agent directories *)
    List.iter (fun agents_path ->
      Sys.readdir agents_path |> Array.iter (fun name ->
        if Filename.check_suffix name ".json" then begin
          let path = Filename.concat agents_path name in
          let json = read_json config path in
          match agent_of_yojson json with
          | Ok agent
            when (not (List.mem agent.name !zombies)) &&
                 (let threshold =
                    if is_keeper_runtime_agent_name agent.name
                    then Env_config.Zombie.keeper_threshold_seconds
                    else Env_config.Zombie.threshold_seconds
                  in
                  Resilience.Zombie.is_zombie ~threshold agent.last_seen) ->
              zombies := agent.name :: !zombies;
              (* Stop heartbeats owned by this zombie agent *)
              let _stopped = Heartbeat.stop_by_agent ~agent_name:agent.name in
              (* Remove agent file *)
              (try Sys.remove path with Sys_error _ -> ())
          | _ -> ()
        end
      )
    ) scan_paths;

    (* Cascade: release tasks claimed by zombie agents *)
    let released_tasks = ref [] in
    if !zombies <> [] then begin
      let backlog = read_backlog config in
      List.iter (fun (task : task) ->
        match task.task_status with
        | Types.Claimed { assignee; _ }
        | Types.InProgress { assignee; _ } when List.mem assignee !zombies ->
            (match !force_release_task_fn config ~agent_name:"gardener" ~task_id:task.id () with
             | Ok msg -> released_tasks := (task.id, msg) :: !released_tasks
             | Error e ->
                 log_event config (Printf.sprintf
                   "{\"type\":\"zombie_cascade_error\",\"task_id\":\"%s\",\"error\":\"%s\",\"ts\":\"%s\"}"
                   task.id (Types.masc_error_to_string e) (now_iso ())))
        | _ -> ()
      ) backlog.tasks
    end;

    (* Update state to remove zombie agents *)
    if !zombies <> [] then begin
      let _ = update_state config (fun s ->
        { s with active_agents = List.filter (fun a -> not (List.mem a !zombies)) s.active_agents }
      ) in

      (* Log event *)
      log_event config (Printf.sprintf
        "{\"type\":\"zombie_cleanup\",\"agents\":%s,\"released_tasks\":%d,\"ts\":\"%s\"}"
        (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) !zombies)))
        (List.length !released_tasks)
        (now_iso ()));

      let task_note = if !released_tasks = [] then ""
        else Printf.sprintf ", released %d orphan task(s)" (List.length !released_tasks)
      in
      Printf.sprintf "🧟 Cleaned up %d zombie agent(s): %s%s"
        (List.length !zombies) (String.concat ", " !zombies) task_note
    end else
      "✅ No zombie agents found"
  end

(** Garbage collection - cleanup zombies, stale tasks, old messages *)
let gc config ?(days=7) () =
  ensure_initialized config;

  let results = ref [] in

  (* 1. Cleanup zombies *)
  let zombie_result = cleanup_zombies config in
  results := zombie_result :: !results;

  (* 2. Archive stale tasks (older than N days, not completed) *)
  let cutoff_time =
    let now = Time_compat.now () in
    now -. (float_of_int days *. 24. *. 60. *. 60.)
  in
  let cutoff_iso =
    let tm = Unix.gmtime cutoff_time in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
      (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1) tm.Unix.tm_mday
      tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
  in

  let backlog = read_backlog config in
  let stale_count = ref 0 in
  let archived_tasks = ref [] in
  let kept_tasks = List.filter (fun task ->
    let is_done = match task.task_status with Done _ -> true | _ -> false in
    let is_old = task.created_at < cutoff_iso in
    if is_old && not is_done then begin
      incr stale_count;
      archived_tasks := task :: !archived_tasks;
      false  (* Remove stale task *)
    end else
      true   (* Keep task *)
  ) backlog.tasks in

  if !stale_count > 0 then begin
    append_archive_tasks config (List.rev !archived_tasks);
    let new_backlog = {
      tasks = kept_tasks;
      last_updated = now_iso ();
      version = backlog.version + 1;
    } in
    write_backlog config new_backlog;
    results := Printf.sprintf "📦 Archived %d stale task(s) (older than %d days)" !stale_count days :: !results
  end else
    results := Printf.sprintf "✅ No stale tasks (threshold: %d days)" days :: !results;

  (* 3. Cleanup old messages - but preserve messages referencing open tasks *)
  let messages_path = messages_dir config in
  let old_msg_count = ref 0 in
  let preserved_count = ref 0 in

  (* Get open task IDs (not Done or Cancelled) *)
  let open_task_ids =
    List.filter_map (fun task ->
      match task.task_status with
      | Done _ | Cancelled _ -> None
      | _ -> Some task.id
    ) backlog.tasks
  in

  (* Helper to check if content mentions an open task *)
  let mentions_open_task content =
    List.exists (fun task_id ->
      try ignore (Str.search_forward (Str.regexp_string task_id) content 0); true
      with Not_found -> false
    ) open_task_ids
  in

  if Sys.file_exists messages_path then begin
    Sys.readdir messages_path |> Array.iter (fun name ->
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat messages_path name in
        let json = read_json config path in
        let ts = Yojson.Safe.Util.(member "timestamp" json |> to_string_option) in
        let content = Yojson.Safe.Util.(member "content" json |> to_string_option)
                      |> Option.value ~default:"" in
        match ts with
        | Some ts when ts < cutoff_iso ->
            (* Preserve if message references an open task *)
            if mentions_open_task content then
              incr preserved_count
            else begin
              Sys.remove path;
              incr old_msg_count
            end
        | _ -> ()
      end
    )
  end;

  if !old_msg_count > 0 || !preserved_count > 0 then begin
    if !old_msg_count > 0 then
      results := Printf.sprintf "🗑️ Deleted %d old message(s) (older than %d days)" !old_msg_count days :: !results;
    if !preserved_count > 0 then
      results := Printf.sprintf "🔒 Preserved %d message(s) referencing open tasks" !preserved_count :: !results
  end else
    results := Printf.sprintf "✅ No old messages (threshold: %d days)" days :: !results;

  (* 4. Cleanup backend pubsub - PostgreSQL specific, no-op for others *)
  let pubsub_cleanup_count = ref 0 in
  (match backend_cleanup_pubsub config ~days ~max_messages:10000 with
   | Ok count when count > 0 ->
       pubsub_cleanup_count := count;
       results := Printf.sprintf "🗃️ Cleaned %d pubsub message(s) from backend" count :: !results
   | Ok _ -> ()  (* No messages to clean *)
   | Error e ->
       results := Printf.sprintf "⚠️ Backend pubsub cleanup failed: %s" (Backend.show_error e) :: !results);

  (* 5. Cleanup orphan keeper sidecar files (.metrics.jsonl/.memory.jsonl without .json) *)
  let keeper_orphan_count = ref 0 in
  let pk_dir = Filename.concat (Filename.concat config.base_path ".masc") "perpetual-keepers" in
  if Sys.file_exists pk_dir then begin
    let entries = Sys.readdir pk_dir |> Array.to_list in
    (* Active keepers = those with a .json config file *)
    let active_keepers = List.filter_map (fun name ->
      if Filename.check_suffix name ".json" && String.length name > 0 && name.[0] <> '_' then
        Some (Filename.chop_suffix name ".json")
      else None
    ) entries in
    (* Find and remove orphan sidecar files *)
    List.iter (fun name ->
      (* Skip global files starting with _ (e.g. _alerts.jsonl) *)
      if String.length name > 0 && name.[0] <> '_' then begin
        let is_metrics = Filename.check_suffix name ".metrics.jsonl" in
        let is_memory = Filename.check_suffix name ".memory.jsonl" in
        if is_metrics || is_memory then begin
          let suffix = if is_metrics then ".metrics.jsonl" else ".memory.jsonl" in
          let base = String.sub name 0 (String.length name - String.length suffix) in
          if not (List.mem base active_keepers) then begin
            (try Sys.remove (Filename.concat pk_dir name)
             with Sys_error _ -> ());
            incr keeper_orphan_count
          end
        end
      end
    ) entries
  end;
  if !keeper_orphan_count > 0 then
    results := Printf.sprintf "🧹 Removed %d orphan keeper sidecar file(s)" !keeper_orphan_count :: !results
  else
    results := "✅ No orphan keeper files" :: !results;

  (* 6. Archive completed/interrupted team sessions older than N days *)
  let session_archive_count = ref 0 in
  let ts_root = Filename.concat (Filename.concat config.base_path ".masc") "team-sessions" in
  if Sys.file_exists ts_root && Sys.is_directory ts_root then begin
    let archive_ts_dir = Filename.concat
      (Filename.concat (Filename.concat config.base_path ".masc") "archive") "team-sessions" in
    Sys.readdir ts_root |> Array.iter (fun session_id ->
      let sdir = Filename.concat ts_root session_id in
      if Sys.is_directory sdir then begin
        let sjson = Filename.concat sdir "session.json" in
        if Sys.file_exists sjson then
          try
            let json = read_json config sjson in
            let status =
              Yojson.Safe.Util.(member "status" json |> to_string_option)
              |> Option.value ~default:"" in
            let updated =
              Yojson.Safe.Util.(member "updated_at_iso" json |> to_string_option)
              |> Option.value ~default:"" in
            if (status = "completed" || status = "interrupted" || status = "cancelled") && updated <> "" && updated < cutoff_iso then begin
              mkdir_p archive_ts_dir;
              let dest = Filename.concat archive_ts_dir session_id in
              (try Unix.rename sdir dest
               with Unix.Unix_error _ ->
                 Log.Misc.error "failed to archive session %s" session_id);
              incr session_archive_count
            end
          with exn ->
            Log.Gc.warn "session archive %s failed: %s" session_id (Printexc.to_string exn)
      end
    )
  end;
  if !session_archive_count > 0 then
    results := Printf.sprintf "📦 Archived %d completed/interrupted/cancelled team session(s)" !session_archive_count :: !results
  else
    results := "✅ No team sessions to archive" :: !results;

  (* 7. CP data cleanup (dead units, stale operations, orphaned detachments) *)
  if not !cp_cleanup_connected then
    log_event config (Printf.sprintf
      "{\"type\":\"gc_warning\",\"msg\":\"cp_cleanup_fn not connected, CP cleanup skipped\",\"ts\":\"%s\"}"
      (now_iso ()));
  let cp_result = !cp_cleanup_fn config in
  let cp_total =
    cp_result.dead_units_removed + cp_result.orphaned_units_removed
    + cp_result.operations_archived + cp_result.detachments_removed
    + cp_result.intents_removed
  in
  if cp_total > 0 then
    results := Printf.sprintf
      "🧹 CP cleanup: %d dead unit(s), %d orphan unit(s), %d operation(s) archived, %d orphan detachment(s), %d dropped intent(s)"
      cp_result.dead_units_removed cp_result.orphaned_units_removed
      cp_result.operations_archived cp_result.detachments_removed
      cp_result.intents_removed :: !results
  else
    results := "✅ No stale CP data" :: !results;
  (* Log event *)
  let cp_json =
    Printf.sprintf "{\"dead_units\":%d,\"orphan_units\":%d,\"ops_archived\":%d,\"orphan_dets\":%d,\"dropped_intents\":%d}"
      cp_result.dead_units_removed cp_result.orphaned_units_removed
      cp_result.operations_archived cp_result.detachments_removed
      cp_result.intents_removed
  in
  log_event config (Printf.sprintf
    "{\"type\":\"gc\",\"stale_tasks\":%d,\"old_messages\":%d,\"preserved\":%d,\"pubsub_cleaned\":%d,\"keeper_orphans\":%d,\"sessions_archived\":%d,\"cp_cleanup\":%s,\"days\":%d,\"ts\":\"%s\"}"
    !stale_count !old_msg_count !preserved_count !pubsub_cleanup_count !keeper_orphan_count !session_archive_count
    cp_json days (now_iso ()));

  String.concat "\n" (List.rev !results)
