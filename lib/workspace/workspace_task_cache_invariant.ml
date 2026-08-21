(** Guard an explicitly declared task-cache signal against canonical backlog state. *)

type signal =
  { subject_agent : string
  ; task_id : string
  }

type rewrite =
  | Unchanged of string
  | Invalidated of string

let rewrite_signal ~config ~module_name ~signal ~content =
  match Task_cache_invariant.fresh_task_status config ~task_id:signal.task_id with
  | Some status when Task_cache_invariant.is_terminal status ->
    Task_cache_invariant.clear_stale_agent_task
      config
      ~agent_name:signal.subject_agent
      ~task_id:signal.task_id
      ~status
      ~module_name;
    (Atomic.get Workspace_hooks.cache_desync_cleared_fn)
      config
      ~module_name
      ~task_id:signal.task_id
      ~status:(Masc_domain.task_status_to_string status);
    Invalidated
      (Printf.sprintf
         "[cache_invalidated] %s: %s cached task %s as active, but it is %s \
          — stale broadcast suppressed"
         module_name
         signal.subject_agent
         signal.task_id
         (Masc_domain.task_status_to_string status))
  | Some _ | None -> Unchanged content
;;
