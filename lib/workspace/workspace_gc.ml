(** Workspace heartbeat and explicit garbage collection.

    Extracted from workspace.ml for modularity.
    Contains: heartbeat and gc. *)

open Masc_domain
open Workspace_utils
open Workspace_state
open Workspace_identity
open Workspace_backlog
open Workspace_task_id

(* Callback refs and types are now in Workspace_hooks. *)

(* Board artifact cleanup is wired via Workspace_hooks callbacks at startup. *)


(* heartbeat_in_workspace removed — workspaces are flattened (#4638). Use heartbeat. *)

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
          Printf.sprintf "%s heartbeat updated" actual_name
      | Error e ->
          Log.Workspace.debug "heartbeat: invalid agent JSON for %s: %s" actual_name e;
          Printf.sprintf "Invalid agent file for %s" actual_name
    )
  end else
    Printf.sprintf "Agent %s not found" agent_name

(** Explicit age-based garbage collection. The caller must choose the retention
    horizon; this layer has no default retention policy. Agent lifecycle is not
    part of GC and remains an explicit operator action. *)
let gc config ~days () =
  if days < 1 then invalid_arg "Workspace_gc.gc: days must be >= 1";
  ensure_initialized config;

  let results = ref [] in

  (* 1. Archive terminal tasks (Done/Cancelled) older than N days, and
        self-heal any non-terminal task a prior buggy GC pass stranded in the
        archive.

        Only terminal states are archive-eligible.  masc_transition and the
        dashboard verification resolve path read the *live* backlog only, so
        archiving a non-terminal task strands it: an AwaitingVerification
        obligation can no longer be approved/rejected and a Claimed/InProgress
        task can no longer be released, with no unarchive path.  RFC-0220
        requires an AwaitingVerification obligation to stay claimable by a
        verifier.  Live incident: task-1537 (submitted 2026-06-29) was orphaned
        into tasks-archive.json for days because the old [not is_done]
        predicate archived every non-[Done] task, including
        AwaitingVerification.

        Archive-eligibility is decided by [task_status_is_terminal] — an
        exhaustive match over [task_status] with no [_] catch-all, so adding a
        new status forces a compile-time decision there rather than silently
        defaulting to "archive". *)
  let cutoff_time =
    let now = Time_compat.now () in
    now -. (float_of_int days *. 24. *. 60. *. 60.)
  in
  let cutoff_iso = Masc_domain.iso8601_of_unix_seconds cutoff_time in

  let backlog = read_backlog config in
  let stale_count = ref 0 in
  let archived_tasks = ref [] in
  let kept_tasks = List.filter (fun task ->
    let is_terminal = Masc_domain.task_status_is_terminal task.task_status in
    let is_old = task.created_at < cutoff_iso in
    if is_old && is_terminal then begin
      incr stale_count;
      archived_tasks := task :: !archived_tasks;
      false  (* Archive: terminal and older than the cutoff. *)
    end else
      true   (* Keep: recent, or non-terminal at any age. *)
  ) backlog.tasks in

  (* Self-healing restore: recover non-terminal obligations a prior pass
     mis-archived.  Restore only ids not already live so a crash between the
     backlog write and the archive drop below cannot duplicate a task. *)
  let orphaned = read_orphaned_nonterminal_tasks config in
  let live_ids = List.map (fun (t : task) -> t.id) kept_tasks in
  let restored =
    List.filter (fun (t : task) -> not (List.mem t.id live_ids)) orphaned
  in
  let restore_count = List.length restored in
  let live_tasks_after_gc = kept_tasks @ restored in

  (* Backlog first: on a crash before the archive is rewritten below, the
     restored task survives in both stores and the next GC pass dedups it. *)
  if !stale_count > 0 || restore_count > 0 then begin
    let new_backlog = {
      tasks = live_tasks_after_gc;
      last_updated = now_iso ();
      version = backlog.version + 1;
    } in
    write_backlog config new_backlog
  end;
  if !stale_count > 0 then append_archive_tasks config (List.rev !archived_tasks);
  (* Drop every orphaned non-terminal entry from the archive, including any that
     was already live (a pure duplicate). *)
  if orphaned <> [] then
    drop_archive_tasks config ~ids:(List.map (fun (t : task) -> t.id) orphaned);
  List.iter (fun (t : task) ->
    let status = Masc_domain.task_status_to_string t.task_status in
    log_event config (`Assoc [
      ("type", `String "task_restored_from_archive");
      ("task_id", `String t.id);
      ("status", `String status);
      ("ts", `String (now_iso ()));
    ]);
    (Atomic.get Workspace_hooks.activity_emit_fn)
      config
      ~actor:Workspace_hooks.{ kind = "system"; id = "keeper-gc" }
      ~subject:Workspace_hooks.{ kind = "task"; id = t.id }
      ~kind:"task.restored_from_archive"
      ~payload:(`Assoc [ ("status", `String status) ])
      ~tags:[ "gc"; "self_heal"; "rfc-0220" ]
      ()
  ) restored;
  (if !stale_count > 0 then
     results :=
       Printf.sprintf "Archived %d terminal task(s) (older than %d days)" !stale_count days
       :: !results
   else
     results :=
       Printf.sprintf "No terminal tasks to archive (threshold: %d days)" days :: !results);
  if restore_count > 0 then
    results :=
      Printf.sprintf "Restored %d non-terminal task(s) from archive" restore_count
      :: !results;

  (* 2. Cleanup old messages - but preserve messages referencing open tasks *)
  let messages_path = messages_dir config in
  let old_msg_count = ref 0 in
  let preserved_count = ref 0 in

  (* Get open task IDs (not Done or Cancelled) *)
  let open_task_ids =
    List.filter_map (fun task ->
      if Masc_domain.task_status_is_terminal task.task_status then None
      else Some task.id
    ) live_tasks_after_gc
  in

  (* Substring check against any open task ID.

     Old version compiled a fresh [Re.t] per (task_id × message), so a
     GC pass over M old messages with N open tasks paid M × N compiles
     before [execp] could even run.  The task ID set is fixed for the
     entire pass, so collapse it into a single alternation DFA compiled
     once outside the message loop. *)
  let mentions_open_task =
    match open_task_ids with
    | [] -> fun _ -> false
    | ids ->
        let re = Re.(compile (alt (List.map str ids))) in
        fun content -> Re.execp re content
  in

  if Sys.file_exists messages_path then begin
    Sys.readdir messages_path |> Array.iter (fun name ->
        Workspace_query.safe_yield ();
      if Filename.check_suffix name ".json" then begin
        let path = Filename.concat messages_path name in
        let json = read_json config path in
        let ts = Json_util.get_string json "timestamp" in
        let content = Json_util.get_string json "content"
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
        | None | Some _ -> ()
      end
    )
  end;

  if !old_msg_count > 0 || !preserved_count > 0 then begin
    if !old_msg_count > 0 then
      results := Printf.sprintf "Deleted %d old message(s) (older than %d days)" !old_msg_count days :: !results;
    if !preserved_count > 0 then
      results := Printf.sprintf "Preserved %d message(s) referencing open tasks" !preserved_count :: !results
  end else
    results := Printf.sprintf "No old messages (threshold: %d days)" days :: !results;

  (* 3. Cleanup backend pubsub - no-op for filesystem backend *)
  let pubsub_cleanup_count = ref 0 in
  (match backend_cleanup_pubsub config ~days ~max_messages:10000 with
   | Ok count when count > 0 ->
       pubsub_cleanup_count := count;
       results := Printf.sprintf "Cleaned %d pubsub message(s) from backend" count :: !results
   | Ok _ -> ()  (* No messages to clean *)
   | Error e ->
       results := Printf.sprintf "Backend pubsub cleanup failed: %s" (Backend_types.show_error e) :: !results);

  (* 4. Cleanup orphan keeper sidecar files (.metrics.jsonl/.memory.jsonl without .json)
        and orphan date-split metrics directories (<name>/metrics/ without <name>.json) *)
  let keeper_orphan_count = ref 0 in
  let pk_dir = Common.keepers_runtime_dir_of_base ~base_path:config.base_path in
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
    results := Printf.sprintf "Removed %d orphan keeper sidecar file(s)" !keeper_orphan_count :: !results
  else
    results := "No orphan keeper files" :: !results;

  (* 5. Archive completed/interrupted team sessions older than N days *)
  let session_archive_count = ref 0 in
  let ts_root = Filename.concat (Common.masc_dir_from_base_path ~base_path:config.base_path) "team-sessions" in
  if Sys.file_exists ts_root && Sys.is_directory ts_root then begin
    let archive_ts_dir = Filename.concat
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:config.base_path) "archive") "team-sessions" in
    Sys.readdir ts_root |> Array.iter (fun session_id ->
        Workspace_query.safe_yield ();
      let sdir = Filename.concat ts_root session_id in
      if Sys.is_directory sdir then begin
        let sjson = Filename.concat sdir "session.json" in
        if Sys.file_exists sjson then
          try
            let json = read_json config sjson in
            let status =
              Json_util.get_string json "status"
              |> Option.value ~default:"" in
            let updated =
              Json_util.get_string json "updated_at_iso"
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
    results := Printf.sprintf "Archived %d completed/interrupted/cancelled team session(s)" !session_archive_count :: !results
  else
    results := "No team sessions to archive" :: !results;

  (* 6. Hard-delete board artifacts (via hooks) *)
  let board_artifact_count = (Atomic.get Workspace_hooks.cleanup_board_artifacts_fn) () in
  if board_artifact_count > 0 then
    results :=
      Printf.sprintf "Removed %d board artifact post(s)"
        board_artifact_count
      :: !results
  else
    results := "No board artifacts" :: !results;

  log_event config (`Assoc [
    ("type", `String "gc");
    ("stale_tasks", `Int !stale_count);
    ("old_messages", `Int !old_msg_count);
    ("preserved", `Int !preserved_count);
    ("pubsub_cleaned", `Int !pubsub_cleanup_count);
    ("keeper_orphans", `Int !keeper_orphan_count);
    ("sessions_archived", `Int !session_archive_count);
    ("board_artifacts", `Int board_artifact_count);
    ("cp_cleanup", `Null);
    ("days", `Int days);
    ("ts", `String (now_iso ()));
  ]);

  String.concat "\n" (List.rev !results)
