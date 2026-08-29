(** Task_cache_invariant — reads canonical task state and the subject's own
    record without collapsing absence, unreadability, and disagreement into
    one another.

    Two lookups, each keeping its failure modes apart:
      - {!read_fresh_task_status} answers what the backlog says about a task.
      - {!agent_current_task_match} answers what one agent record caches, and
        says so when the record could not be read at all.

    {!clear_stale_agent_task_if_matching} clears [current_task] on a matching
    record and logs a [cache_desync.cleared] event.  Whether the caller then
    suppresses, rejects, or reports a dependency failure is the caller's
    decision, made on the returned variant.

    @since #13397 — broadcast / mention desync. *)

open Masc_domain
open Workspace_utils

type fresh_task_lookup =
  | Found of Masc_domain.task_status
  | Absent
  | Unavailable of string

(** Read the current task status directly from the backlog (snapshot read,
    no write lock), preserving absence and read failure as distinct facts. *)
let read_fresh_task_status config ~(task_id : string) : fresh_task_lookup =
  match Workspace_backlog.read_backlog_r config with
  | Error detail -> Unavailable detail
  | Ok backlog ->
    (match
       List.find_opt
         (fun (t : Masc_domain.task) -> String.equal t.id task_id)
         backlog.tasks
     with
     | Some task -> Found task.task_status
     | None -> Absent)
;;

(** What one agent record says about a task, with the ways the answer can be
    unavailable kept apart from the answer itself. *)
type agent_task_match =
  | Matches
  | Mismatch
  | Missing
  | Unreadable of string

(** [is_terminal status] returns [true] iff the status is [Done _] or
    [Cancelled _].  SSOT: [Masc_domain.task_status_is_terminal]. *)
let is_terminal = Masc_domain.task_status_is_terminal

(** Why an agent record had its [current_task] cleared.

    [After_commit] is the routine sweep a writer runs once its backlog commit
    lands: the previous assignee stops owning a task that just moved. Nothing
    was out of step. [Desync] is the reactive path, which clears only after
    reading the canonical backlog and finding the task terminal or gone.

    Both used to emit [cache_desync.cleared]. Two thirds of 3,000 recorded
    events came from [transition_task_r], an after-commit site, so the count
    could not answer whether agent caches actually drift -- the question
    #27411 has to settle before deciding what the seven repair sites are
    for. *)
type clear_cause =
  | After_commit
  | Desync

let clear_cause_event_type = function
  | After_commit -> "task_cache.cleared_after_commit"
  | Desync -> "cache_desync.cleared"

let emit_cache_clear_event config ~cause ~agent_name ~task_id ~status_label ~module_name =
  try
    log_event config
      (`Assoc
        [ "type", `String (clear_cause_event_type cause)
        ; "module", `String module_name
        ; "agent", `String agent_name
        ; "task_id", `String task_id
        ; "ts", `String (now_iso ())
        ])
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Misc.warn
      "task_cache_invariant: log_event failed (%s %s): %s"
      module_name
      task_id
      (Printexc.to_string exn)
;;

let agent_file config agent_name =
  Filename.concat (agents_dir config) (safe_filename agent_name ^ ".json")
;;

let agent_current_task_match config ~agent_name ~task_id =
  let path = agent_file config agent_name in
  if not (path_exists config path)
  then Missing
  else
    with_file_lock config path (fun () ->
      match read_json_result config path with
      | Error detail -> Unreadable detail
      | Ok json ->
        (match agent_of_yojson json with
         | Ok agent -> if agent.current_task = Some task_id then Matches else Mismatch
         | Error detail -> Unreadable detail))
;;

let clear_stale_agent_task_if_matching
      config
      ~(cause : clear_cause)
      ~(agent_name : string)
      ~(task_id : string)
      ~(status_label : string)
      ~(module_name : string)
  =
  let path =
    agent_file config agent_name
  in
  let outcome =
    if not (path_exists config path)
    then Missing
    else
      with_file_lock config path (fun () ->
        match read_json_result config path with
        | Error detail -> Unreadable detail
        | Ok json ->
          (match agent_of_yojson json with
           | Ok agent when agent.current_task = Some task_id ->
             let updated =
               { agent with status = Masc_domain.Active; current_task = None }
             in
             write_json config path (agent_to_yojson updated);
             Matches
           | Ok _ -> Mismatch
           | Error detail -> Unreadable detail))
  in
  (match outcome with
   | Matches ->
     emit_cache_clear_event config ~cause ~agent_name ~task_id ~status_label ~module_name
   | Mismatch | Missing | Unreadable _ -> ());
  outcome
;;

(** Clear the agent's [current_task] field on disk when it equals [task_id]
    and log one diagnostic event named by [cause]. *)
let clear_stale_agent_task config ~cause ~agent_name ~task_id ~status ~module_name =
  ignore
    (clear_stale_agent_task_if_matching
       config
       ~cause
       ~agent_name
       ~task_id
       ~status_label:(Masc_domain.task_status_to_string status)
       ~module_name)
;;

(** Scan every on-disk agent record and clear [current_task] when it equals
    [task_id].  Use this when the backlog no longer references the task
    (terminal status or deletion) and the exact previous assignee is not
    known.  Logs one event per affected agent, named by [cause].

    The read is best-effort and unlocked; [clear_stale_agent_task] re-checks
    the match under the per-agent file lock before writing, so the worst race
    is a no-op or a duplicate log rather than a corrupt agent record. *)
let clear_stale_agent_task_for_task
      config
      ~(cause : clear_cause)
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
                        ~cause
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
