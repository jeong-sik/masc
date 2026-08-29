(** Workspace heartbeat and explicit garbage collection.

    Extracted from workspace.ml for modularity.
    Contains: heartbeat and gc. *)

open Masc_domain
open Workspace_utils
open Workspace_identity
open Workspace_backlog
open Workspace_task_id

(* Callback refs and types are now in Workspace_hooks. *)

(* Board artifact cleanup is wired via Workspace_hooks callbacks at startup. *)



type heartbeat_outcome =
  | Heartbeat_updated of string
  | Agent_file_invalid of string
  | Agent_not_found of string

let heartbeat_message = function
  | Heartbeat_updated actual_name -> Printf.sprintf "%s heartbeat updated" actual_name
  | Agent_file_invalid actual_name -> Printf.sprintf "Invalid agent file for %s" actual_name
  | Agent_not_found agent_name -> Printf.sprintf "Agent %s not found" agent_name

let heartbeat config ~agent_name =
  ensure_initialized config;
  let actual_name = resolve_agent_name config agent_name in
  let filename = safe_filename actual_name ^ ".json" in
  let agent_file = Filename.concat (agents_dir config) filename in
  if path_exists config agent_file then begin
    with_file_lock config agent_file (fun () ->
      match read_agent config agent_file with
      | Ok agent ->
          let updated = { agent with last_seen = now_iso () } in
          write_json config agent_file (agent_to_yojson updated);
          Heartbeat_updated actual_name
      | Error e ->
          Log.Workspace.debug "heartbeat: invalid agent JSON for %s: %s" actual_name e;
          Agent_file_invalid actual_name
    )
  end else
    Agent_not_found agent_name

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
        obligation can no longer receive an authority verdict and a
        Claimed/InProgress task can no longer be released, with no unarchive
        path. Live incident: task-1537 (submitted 2026-06-29) was orphaned
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

  let orphaned = read_orphaned_nonterminal_tasks config in
  let live_tasks_after_gc, archived_tasks, restored =
    let lock_path = backlog_lock_path config in
    with_file_lock config lock_path (fun () ->
      let backlog =
        match read_backlog_r config with
        | Ok backlog -> backlog
        | Error message -> raise (Backlog_read_failed message)
      in
      let kept_tasks, archived_tasks =
        List.partition
          (fun task ->
             let is_terminal =
               Masc_domain.task_status_is_terminal task.task_status
             in
             let is_old = task.created_at < cutoff_iso in
             not (is_old && is_terminal))
          backlog.tasks
      in

      (* Self-healing restore: recover non-terminal obligations a prior pass
         mis-archived. Restore only ids not already live so a crash between the
         backlog write and the archive drop below cannot duplicate a task. *)
      let live_ids = List.map (fun (t : task) -> t.id) kept_tasks in
      let restored =
        List.filter (fun (t : task) -> not (List.mem t.id live_ids)) orphaned
      in
      let live_tasks_after_gc = kept_tasks @ restored in

      (* Backlog first: on a crash before the archive is rewritten below, the
         restored task survives in both stores and the next GC pass dedups it.
         The shared backlog lock keeps this read-modify-write on the same
         revision lineage as task creation and transitions. *)
      if archived_tasks <> [] || restored <> [] then begin
        (* [write_backlog] stamps version/last_updated at the commit point. *)
        let new_backlog = { backlog with tasks = live_tasks_after_gc } in
        write_backlog config new_backlog
      end;
      live_tasks_after_gc, archived_tasks, restored)
  in
  (* Archive I/O has its own lock and is intentionally outside the contended
     backlog critical section. The backlog commit remains first, preserving
     the existing restore crash order; a subsequent GC pass deduplicates a
     restored task left in both stores. *)
  if archived_tasks <> [] then append_archive_tasks config archived_tasks;
  (* Drop every orphaned non-terminal entry from the archive, including any
     that was already live (a pure duplicate). *)
  if orphaned <> [] then
    drop_archive_tasks config ~ids:(List.map (fun (t : task) -> t.id) orphaned);
  let stale_count = List.length archived_tasks in
  let restore_count = List.length restored in
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
  (if stale_count > 0 then
     results :=
       Printf.sprintf "Archived %d terminal task(s) (older than %d days)" stale_count days
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

  log_event config (`Assoc [
    ("type", `String "gc");
    ("preserved", `Int !preserved_count);
    ("days", `Int days);
    ("ts", `String (now_iso ()));
  ]);

  String.concat "\n" (List.rev !results)
