(** Guard an agent-owned task cache against canonical backlog state. *)

type rewrite =
  | Unchanged of string
  | Invalidated of string

let rewrite_current_task ~config ~from_agent ~module_name ~task_id ~content =
  match Task_cache_invariant.fresh_task_status config ~task_id with
  | Some status when Task_cache_invariant.is_terminal status ->
    Task_cache_invariant.clear_stale_agent_task
      config
      ~agent_name:from_agent
      ~task_id
      ~status
      ~module_name;
    (Atomic.get Workspace_hooks.cache_desync_cleared_fn)
      config
      ~module_name
      ~task_id
      ~status:(Masc_domain.task_status_to_string status);
    Invalidated
      (Printf.sprintf
         "[cache_invalidated] %s: task %s is %s \
          — stale broadcast suppressed"
         module_name
         task_id
         (Masc_domain.task_status_to_string status))
  | Some _ | None -> Unchanged content
;;
