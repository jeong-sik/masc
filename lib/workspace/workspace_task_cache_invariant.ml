(** Guard an explicitly declared task-cache signal against canonical backlog state. *)

type signal =
  { subject_agent : string
  ; task_id : string
  }

type rewrite =
  | Unchanged of string
  | Invalidated of string
  | Rejected of string
  | Dependency_unavailable of string

let invalidated_content ~module_name ~signal ~status_label =
  Printf.sprintf
    "[cache_invalidated] %s: %s cached task %s as active, but canonical state is %s \
     — stale broadcast suppressed"
    module_name
    signal.subject_agent
    signal.task_id
    status_label
;;

let reject_mismatch signal =
  Rejected
    (Printf.sprintf
       "task cache signal rejected: subject %s does not currently cache task %s"
       signal.subject_agent
       signal.task_id)
;;

let reject_missing_subject signal =
  Rejected
    (Printf.sprintf
       "task cache signal rejected: subject %s has no agent record"
       signal.subject_agent)
;;

let subject_unreadable signal detail =
  Dependency_unavailable
    (Printf.sprintf
       "task cache signal subject record unreadable for %s: %s"
       signal.subject_agent
       detail)
;;

(* Clearing and reporting are the same decision on both terminal and absent
   canonical state, so they read one match. An unreadable subject record is a
   failure to look, never a subject that disagrees. *)
let clear_and_report ~config ~module_name ~signal ~status_label =
  match
    Task_cache_invariant.clear_stale_agent_task_if_matching
      config
      ~cause:Task_cache_invariant.Desync
      ~agent_name:signal.subject_agent
      ~task_id:signal.task_id
      ~status_label
      ~module_name
  with
  | Task_cache_invariant.Matches ->
    (Atomic.get Workspace_hooks.cache_desync_cleared_fn)
      config
      ~module_name
      ~task_id:signal.task_id
      ~status:status_label;
    Invalidated (invalidated_content ~module_name ~signal ~status_label)
  | Task_cache_invariant.Mismatch -> reject_mismatch signal
  | Task_cache_invariant.Missing -> reject_missing_subject signal
  | Task_cache_invariant.Unreadable detail -> subject_unreadable signal detail
;;

let rewrite_signal ~config ~module_name ~signal ~content =
  match Task_cache_invariant.read_fresh_task_status config ~task_id:signal.task_id with
  | Task_cache_invariant.Unavailable detail ->
    Dependency_unavailable
      (Printf.sprintf "task cache signal canonical backlog unavailable: %s" detail)
  | Task_cache_invariant.Found status when Task_cache_invariant.is_terminal status ->
    clear_and_report
      ~config
      ~module_name
      ~signal
      ~status_label:(Masc_domain.task_status_to_string status)
  | Task_cache_invariant.Found _ ->
    (match
       Task_cache_invariant.agent_current_task_match
         config
         ~agent_name:signal.subject_agent
         ~task_id:signal.task_id
     with
     | Task_cache_invariant.Matches -> Unchanged content
     | Task_cache_invariant.Mismatch -> reject_mismatch signal
     | Task_cache_invariant.Missing -> reject_missing_subject signal
     | Task_cache_invariant.Unreadable detail -> subject_unreadable signal detail)
  | Task_cache_invariant.Absent ->
    clear_and_report ~config ~module_name ~signal ~status_label:"absent"
;;
