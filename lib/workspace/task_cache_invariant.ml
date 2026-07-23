(** Task_cache_invariant — Fleet-wide guard against stale task-cache emissions.

    Any keeper module that maintains its own task-state cache MUST call
    [with_fresh_task_status] before emitting broadcasts, mentions, or
    transitions tied to a specific task ID.  Callers that need finer control
    can compose [fresh_task_status] + [is_terminal] directly.

    If the backlog reports the task as terminal (Done / Cancelled) while
    the caller's cache is still active the guard:
      1. Clears [current_task] on the agent record when it matches [task_id].
      2. Logs a [cache_desync.cleared] event with module identity.
      3. Returns [None] so callers skip the original emission.

    The caller is responsible for emitting a single [cache_invalidated]
    broadcast in place of the original message (typically by passing the
    replacement content directly to [Workspace_broadcast.broadcast]).

    @since #13397 — fleet-wide invariant for broadcast / mention desync. *)

open Masc_domain
open Workspace_utils

(** Read the current task status directly from the backlog (snapshot read,
    no write lock).  Returns [None] when the task is absent or the backlog
    cannot be read. *)
let fresh_task_status config ~(task_id : string)
    : Masc_domain.task_status option =
  match Workspace_backlog.read_backlog_r config with
  | Error _ -> None
  | Ok backlog ->
      List.find_opt
        (fun (t : Masc_domain.task) -> String.equal t.id task_id)
        backlog.tasks
      |> Option.map (fun (t : Masc_domain.task) -> t.task_status)

(** [is_terminal status] returns [true] iff the status is [Done _] or
    [Cancelled _].  SSOT: [Masc_domain.task_status_is_terminal]. *)
let is_terminal = Masc_domain.task_status_is_terminal

(** Clear the agent's [current_task] field on disk when it equals [task_id]
    and log a [cache_desync.cleared] diagnostic event. *)
let clear_stale_agent_task
      config
      ~(agent_name : string)
      ~(task_id : string)
      ~(status : Masc_domain.task_status)
      ~(module_name : string)
    : unit =
  (* 1. Clear agent state on disk *)
  let agent_file =
    Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
  in
  if Sys.file_exists agent_file then
    with_file_lock config agent_file (fun () ->
      let json = read_json config agent_file in
      match agent_of_yojson json with
      | Ok agent when agent.current_task = Some task_id ->
          let updated =
            { agent with status = Masc_domain.Active; current_task = None }
          in
          write_json config agent_file (agent_to_yojson updated)
      | Ok _ -> ()
      | Error msg ->
          Log.Misc.warn
            "task_cache_invariant: agent parse failed for %s: %s"
            agent_name msg);
  (* 2. Log the desync event *)
  (try
     log_event config
       (`Assoc
           [ ("type", `String "cache_desync.cleared")
           ; ("module", `String module_name)
           ; ("agent", `String agent_name)
           ; ("task_id", `String task_id)
           ; ("backlog_status",
              `String (Masc_domain.task_status_to_string status))
           ; ("ts", `String (now_iso ()))
           ])
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Log.Misc.warn
         "task_cache_invariant: log_event failed (%s %s): %s"
         module_name task_id (Printexc.to_string exn))

(** Scan every on-disk agent record and clear [current_task] when it equals
    [task_id].  Use this when the backlog no longer references the task
    (terminal status or deletion) and the exact previous assignee is not
    known.  Logs one [cache_desync.cleared] event per affected agent.

    The read is best-effort and unlocked; [clear_stale_agent_task] re-checks
    the match under the per-agent file lock before writing, so the worst race
    is a no-op or a duplicate log rather than a corrupt agent record. *)
let clear_stale_agent_task_for_task
      config
      ~(task_id : string)
      ~(status : Masc_domain.task_status)
      ~(module_name : string)
    : unit =
  let agents_path = agents_dir config in
  if path_exists config agents_path
  then
    (try
       let agent_files = Sys.readdir agents_path in
       Array.iter
         (fun name ->
            if Filename.check_suffix name ".json"
            then (
              let agent_file = Filename.concat agents_path name in
              match read_json_opt config agent_file with
              | None -> ()
              | Some json -> (
                  match agent_of_yojson json with
                  | Ok agent when agent.current_task = Some task_id ->
                      clear_stale_agent_task config
                        ~agent_name:agent.name
                        ~task_id
                        ~status
                        ~module_name
                  | Ok _ -> ()
                  | Error msg ->
                    Log.Misc.warn
                      "task_cache_invariant: agent parse failed for %s (%s): %s"
                      agent_file
                      module_name
                      msg)))
         agent_files
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | Sys_error msg ->
         Log.Misc.warn
           "task_cache_invariant: agent directory scan failed (%s): %s"
           module_name
           msg
     | exn ->
         Log.Misc.warn
           "task_cache_invariant: unexpected scan error (%s): %s"
           module_name
           (Printexc.to_string exn))

(** Core invariant wrapper.

    [with_fresh_task_status config ~agent_name ~task_id ~module_name f]
    re-reads [task_id] from the backlog.  If the status is terminal:
      - clears [current_task] on the agent record when it matches [task_id]
      - logs a [cache_desync.cleared] event
      - returns [None] — callers MUST skip the original emission and instead
        emit a single [cache_invalidated] broadcast

    If the task is still active, calls [f status] and returns [Some result].

    Returns [None] when the task is not found (treat as unknown; caller decides).

    @param module_name  Short ASCII label for the diagnostic log,
    e.g. ["taskmaster.broadcast"] or ["mention_tracker.emit"]. *)
let with_fresh_task_status
      config
      ~(agent_name : string)
      ~(task_id : string)
      ~(module_name : string)
      (f : Masc_domain.task_status -> 'a)
    : 'a option =
  match fresh_task_status config ~task_id with
  | Some status when is_terminal status ->
      clear_stale_agent_task config ~agent_name ~task_id ~status ~module_name;
      None
  | Some status ->
      Some (f status)
  | None ->
      (* Task not found in backlog — conservative: return None so the caller
         treats it as though suppressed.  Callers that need to distinguish
         "terminal" from "absent" should use [fresh_task_status] directly. *)
      None
