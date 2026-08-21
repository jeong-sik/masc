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

let rewrite_signal ~config ~module_name ~signal ~content =
  match Task_cache_invariant.read_fresh_task_status config ~task_id:signal.task_id with
  | Task_cache_invariant.Unavailable detail ->
    Dependency_unavailable
      (Printf.sprintf "task cache signal canonical backlog unavailable: %s" detail)
  | Task_cache_invariant.Found status when Task_cache_invariant.is_terminal status ->
    let status_label = Masc_domain.task_status_to_string status in
    if
      Task_cache_invariant.clear_stale_agent_task_if_matching
        config
        ~agent_name:signal.subject_agent
        ~task_id:signal.task_id
        ~status_label
        ~module_name
    then (
      (Atomic.get Workspace_hooks.cache_desync_cleared_fn)
        config
        ~module_name
        ~task_id:signal.task_id
        ~status:status_label;
      Invalidated (invalidated_content ~module_name ~signal ~status_label))
    else reject_mismatch signal
  | Task_cache_invariant.Found _ ->
    if
      Task_cache_invariant.agent_current_task_matches
        config
        ~agent_name:signal.subject_agent
        ~task_id:signal.task_id
    then Unchanged content
    else reject_mismatch signal
  | Task_cache_invariant.Absent ->
    let status_label = "absent" in
    if
      Task_cache_invariant.clear_stale_agent_task_if_matching
        config
        ~agent_name:signal.subject_agent
        ~task_id:signal.task_id
        ~status_label
        ~module_name
    then (
      (Atomic.get Workspace_hooks.cache_desync_cleared_fn)
        config
        ~module_name
        ~task_id:signal.task_id
        ~status:status_label;
      Invalidated (invalidated_content ~module_name ~signal ~status_label))
    else reject_mismatch signal
;;
