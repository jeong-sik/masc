(** Room GC - Heartbeat, Zombie Cleanup, and Garbage Collection.

    Extracted from room.ml for modularity.
    Contains: heartbeat_in_room, heartbeat, cleanup_zombies, gc. *)

open Types
open Room_utils
open Room_state

(* Callback refs and types are now in Room_hooks. *)

(* Board artifact cleanup and governance purge are now in Room_hooks callbacks.
   The actual implementations are wired by room.ml at startup. *)


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
      match read_agent_with_repair scoped agent_file with
      | Ok agent ->
          let updated = { agent with last_seen = now_iso () } in
          write_json scoped agent_file (agent_to_yojson updated);
          Printf.sprintf "💓 %s heartbeat updated in %s" actual_name room_id
      | Error e ->
          Log.Room.debug "heartbeat_scoped: invalid agent JSON for %s in %s: %s"
            actual_name room_id e;
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
      match read_agent_with_repair config agent_file with
      | Ok agent ->
          let updated = { agent with last_seen = now_iso () } in
          write_json config agent_file (agent_to_yojson updated);
          Printf.sprintf "💓 %s heartbeat updated" actual_name
      | Error e ->
          Log.Room.debug "heartbeat: invalid agent JSON for %s: %s" actual_name e;
          Printf.sprintf "⚠ Invalid agent file for %s" actual_name
    )
  end else
    Printf.sprintf "⚠ Agent %s not found" agent_name

(** Cleanup zombie agents - removes stale agents.
    [keeper_threshold_sec] and [agent_threshold_sec] control the inactivity
    window before an agent is considered a zombie. *)
let cleanup_zombies
    ?(keeper_threshold_sec = 3600.0)
    ?(agent_threshold_sec = 300.0)
    config =
  ensure_initialized config;

  (* Single path: agents_dir derives from config.scope *)
  let agents_path = agents_dir config in
  let scan_paths =
    if Sys.file_exists agents_path then [ agents_path ] else []
  in
  if scan_paths = [] then
    "📋 No agents directory"
  else begin
    (* Phase 1: Detect zombie agents (no side effects) *)
    let zombie_entries = ref [] in (* (name, path) list *)
    List.iter (fun agents_path ->
      Sys.readdir agents_path |> Array.iter (fun name ->
        Room_query.safe_yield ();
        if Filename.check_suffix name ".json" then begin
          let path = Filename.concat agents_path name in
          match read_agent_with_repair config path with
          | Ok agent
            when (not (List.exists (fun (n, _) -> n = agent.name) !zombie_entries)) &&
                 (let threshold =
                    if Resilience.Zombie.is_keeper ~name:agent.name ~agent_type:agent.agent_type
                    then keeper_threshold_sec
                    else agent_threshold_sec
                  in
                  Resilience.Zombie.is_zombie ~threshold agent.last_seen) ->
              zombie_entries := (agent.name, path) :: !zombie_entries
          | Ok _ -> () (* not a zombie, skip *)
          | Error err ->
              Log.Gc.warn "removing broken agent file %s: %s" name err;
              (try
                 delete_path config path;
                 (* delete_path only removes the backend entry for dual-write
                    backends; the local mirror file must be removed separately
                    to prevent repeated GC warnings on each scan cycle. *)
                 (try Sys.remove path with Sys_error _ -> ())
               with exn ->
                 Log.Gc.warn "failed to remove broken agent %s: %s"
                   path (Printexc.to_string exn))
        end
      )
    ) scan_paths;

    if !zombie_entries = [] then
      "✅ No zombie agents found"
    else begin
      (* Phase 2: Transition status to Inactive + stop heartbeats.
         Note: If later phases fail (task release or file deletion), the agent
         remains in active_agents with an Inactive file. This is intentional:
         Inactive+in-list is self-healing (next GC cycle cleans up), whereas
         Active+dead (the old behavior) is invisible to monitoring. *)
      List.iter (fun (name, path) ->
        (try
          match read_agent_with_repair config path with
          | Ok agent ->
              let updated = { agent with status = Inactive; last_seen = now_iso () } in
              write_json config path (agent_to_yojson updated)
          | Error err -> Log.Gc.warn "gc status update parse error for %s: %s" name err
        with Sys_error msg -> Log.Gc.warn "gc status update I/O error for %s: %s" name msg);
        let _stopped = Heartbeat.stop_by_agent ~agent_name:name in
        ()
      ) !zombie_entries;

      (* Phase 3: Release tasks — track failures per agent *)
      let release_failed_agents = ref [] in
      let released_tasks = ref [] in
      let backlog = read_backlog config in
      List.iter (fun (task : task) ->
        match task.task_status with
        | Types.Claimed { assignee; _ }
        | Types.InProgress { assignee; _ }
          when List.exists (fun (n, _) -> n = assignee) !zombie_entries ->
            (match !Room_hooks.force_release_task_fn config ~agent_name:"keeper-gc" ~task_id:task.id () with
             | Ok msg -> released_tasks := (task.id, msg) :: !released_tasks
             | Error e ->
                 if not (List.mem assignee !release_failed_agents) then
                   release_failed_agents := assignee :: !release_failed_agents;
                 log_event config (Printf.sprintf
                   "{\"type\":\"zombie_cascade_error\",\"task_id\":\"%s\",\"agent\":\"%s\",\"error\":\"%s\",\"ts\":\"%s\"}"
                   task.id assignee (Types.masc_error_to_string e) (now_iso ())))
        | _ -> ()
      ) backlog.tasks;

      (* Phase 4: Delete files — skip agents with release failures *)
      let successfully_cleaned = ref [] in
      List.iter (fun (name, path) ->
        if List.mem name !release_failed_agents then
          Log.Gc.warn "skipping file removal for %s: task release failed" name
        else begin
          match Sys.remove path with
          | () -> successfully_cleaned := name :: !successfully_cleaned
          | exception Sys_error msg ->
              Log.Gc.warn "failed to remove zombie agent file %s: %s" path msg
        end
      ) !zombie_entries;

      (* Phase 5: Update state — only remove successfully cleaned agents *)
      if !successfully_cleaned <> [] then begin
        let _ = update_state config (fun s ->
          { s with active_agents =
              List.filter (fun a -> not (List.mem a !successfully_cleaned)) s.active_agents }
        ) in
        log_event config (Printf.sprintf
          "{\"type\":\"zombie_cleanup\",\"agents\":%s,\"released_tasks\":%d,\"skipped\":%d,\"ts\":\"%s\"}"
          (Yojson.Safe.to_string (`List (List.map (fun s -> `String s) !successfully_cleaned)))
          (List.length !released_tasks)
          (List.length !zombie_entries - List.length !successfully_cleaned)
          (now_iso ()))
      end;

      let total = List.length !zombie_entries in
      let cleaned = List.length !successfully_cleaned in
      let skipped = total - cleaned in
      let task_note = if !released_tasks = [] then ""
        else Printf.sprintf ", released %d orphan task(s)" (List.length !released_tasks)
      in
      if skipped > 0 then
        Printf.sprintf "🧟 Cleaned %d/%d zombie(s): %s%s (⚠ %d skipped due to errors)"
          cleaned total (String.concat ", " !successfully_cleaned) task_note skipped
      else
        Printf.sprintf "🧟 Cleaned up %d zombie agent(s): %s%s"
          cleaned (String.concat ", " !successfully_cleaned) task_note
    end
  end

(** Garbage collection - cleanup zombies, stale tasks, old messages *)
let gc config ?(days=7) () =
  let days = max 1 days in
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
      let re = Re.(compile (str task_id)) in
      Re.execp re content
    ) open_task_ids
  in

  if Sys.file_exists messages_path then begin
    Sys.readdir messages_path |> Array.iter (fun name ->
        Room_query.safe_yield ();
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
       results := Printf.sprintf "⚠️ Backend pubsub cleanup failed: %s" (Backend_types.show_error e) :: !results);

  (* 5. Cleanup orphan keeper sidecar files (.metrics.jsonl/.memory.jsonl without .json)
        and orphan date-split metrics directories (<name>/metrics/ without <name>.json) *)
  let keeper_orphan_count = ref 0 in
  let pk_dir = Filename.concat (Filename.concat config.base_path ".masc") "keepers" in
  if Sys.file_exists pk_dir then begin
    let entries = Sys.readdir pk_dir |> Array.to_list in
    (* Active keepers = those with a .json config file *)
    let active_keepers = List.filter_map (fun name ->
      if Filename.check_suffix name ".json" && String.length name > 0 && name.[0] <> '_' then
        Some (Filename.chop_suffix name ".json")
      else None
    ) entries in
    (* Find and remove orphan legacy sidecar files *)
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
    ) entries;
    (* Find and remove orphan date-split metrics directories *)
    let rec rmdir_recursive path =
      if Sys.file_exists path && Sys.is_directory path then begin
        Array.iter (fun child ->
          let child_path = Filename.concat path child in
          if Sys.is_directory child_path then rmdir_recursive child_path
          else (try Sys.remove child_path with Sys_error _ -> ())
        ) (Sys.readdir path);
        (try Unix.rmdir path with Unix.Unix_error _ -> ())
      end
    in
    List.iter (fun name ->
      if String.length name > 0 && name.[0] <> '_'
         && not (Filename.check_suffix name ".json")
         && not (Filename.check_suffix name ".jsonl") then begin
        let dir_path = Filename.concat pk_dir name in
        if Sys.file_exists dir_path && Sys.is_directory dir_path then begin
          let metrics_dir = Filename.concat dir_path "metrics" in
          if not (List.mem name active_keepers)
             && Sys.file_exists metrics_dir && Sys.is_directory metrics_dir then begin
            rmdir_recursive metrics_dir;
            (* Remove the keeper dir itself if now empty *)
            (try
               if Array.length (Sys.readdir dir_path) = 0 then
                 Unix.rmdir dir_path
             with Sys_error _ | Unix.Unix_error _ -> ());
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
        Room_query.safe_yield ();
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
          with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
            Log.Gc.warn "session archive %s failed: %s" session_id (Printexc.to_string exn)
      end
    )
  end;
  if !session_archive_count > 0 then
    results := Printf.sprintf "📦 Archived %d completed/interrupted/cancelled team session(s)" !session_archive_count :: !results
  else
    results := "✅ No team sessions to archive" :: !results;

  (* 7. Hard-delete board/governance artifacts (via hooks) *)
  let board_artifact_count = !Room_hooks.cleanup_board_artifacts_fn () in
  let governance_test_artifact_count, governance_artifact_count =
    !Room_hooks.governance_purge_fn config.base_path
  in
  if board_artifact_count > 0 then
    results :=
      Printf.sprintf "🧽 Removed %d board artifact post(s)"
        board_artifact_count
      :: !results
  else
    results := "✅ No board artifacts" :: !results;
  if governance_test_artifact_count > 0 || governance_artifact_count > 0 then
    results :=
      Printf.sprintf "⚖️ Removed %d governance artifact case(s) and %d stale test case(s)"
        governance_artifact_count governance_test_artifact_count
      :: !results
  else
    results := "✅ No governance artifacts" :: !results;

  (* 8. CP data cleanup (dead units, stale operations, orphaned detachments) *)
  if not !Room_hooks.cp_cleanup_connected then
    log_event config (Printf.sprintf
      "{\"type\":\"gc_warning\",\"msg\":\"cp_cleanup_fn not connected, CP cleanup skipped\",\"ts\":\"%s\"}"
      (now_iso ()));
  let cp_result = !Room_hooks.cp_cleanup_fn config in
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
  (* 9. Archive stale room directories (no file modified in N days).
         Prevents .masc/rooms/ from growing unbounded and slowing down
         snapshot computation (each room adds hundreds of JSON files). *)
  let room_archive_count = ref 0 in
  let rooms_root = rooms_root_dir config in
  if Sys.file_exists rooms_root && Sys.is_directory rooms_root then begin
    let archive_rooms_dir = Filename.concat
      (Filename.concat (masc_root_dir config) "archive") "rooms" in
    let now_f = Time_compat.now () in
    let threshold_sec = float_of_int days *. 86400.0 in
    Sys.readdir rooms_root |> Array.iter (fun room_id ->
        Room_query.safe_yield ();
      let room_dir = Filename.concat rooms_root room_id in
      if Sys.is_directory room_dir then begin
        (* Find most recent mtime across all files in the room *)
        let max_mtime = ref 0.0 in
        let rec scan dir =
          (try
            Sys.readdir dir |> Array.iter (fun name ->
              Room_query.safe_yield ();
              let path = Filename.concat dir name in
              if Sys.is_directory path then scan path
              else
                (try
                  let st = Unix.stat path in
                  if st.Unix.st_mtime > !max_mtime then
                    max_mtime := st.Unix.st_mtime
                with Unix.Unix_error _ -> ()))
          with Sys_error _ -> ())
        in
        scan room_dir;
        let age_sec = now_f -. !max_mtime in
        if !max_mtime > 0.0 && age_sec > threshold_sec then begin
          mkdir_p archive_rooms_dir;
          let dest = Filename.concat archive_rooms_dir room_id in
          (try Unix.rename room_dir dest
           with Unix.Unix_error _ ->
             Log.Gc.warn "failed to archive room %s" room_id);
          incr room_archive_count
        end
      end
    )
  end;
  if !room_archive_count > 0 then
    results := Printf.sprintf "📦 Archived %d stale room(s) (no activity for %d+ days)" !room_archive_count days :: !results
  else
    results := "✅ No stale rooms" :: !results;

  log_event config (Printf.sprintf
    "{\"type\":\"gc\",\"stale_tasks\":%d,\"old_messages\":%d,\"preserved\":%d,\"pubsub_cleaned\":%d,\"keeper_orphans\":%d,\"sessions_archived\":%d,\"board_artifacts\":%d,\"governance_test_artifacts\":%d,\"governance_artifacts\":%d,\"rooms_archived\":%d,\"cp_cleanup\":%s,\"days\":%d,\"ts\":\"%s\"}"
    !stale_count !old_msg_count !preserved_count !pubsub_cleanup_count !keeper_orphan_count !session_archive_count
    board_artifact_count governance_test_artifact_count governance_artifact_count
    !room_archive_count cp_json days (now_iso ()));

  String.concat "\n" (List.rev !results)
