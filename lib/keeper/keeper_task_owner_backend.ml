(** Keeper-owned task owner hooks behind the tool/task boundary. *)

let is_keeper_agent_identity config ~agent_name =
  Keeper_registry.all ~base_path:config.Workspace.base_path ()
  |> List.exists (fun (entry : Keeper_registry.registry_entry) ->
       String.equal entry.meta.agent_name agent_name)
;;

let sync_current_task_binding config ~agent_name =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name
    ~config
    ~agent_name
;;

let install_hooks () =
  let is_keeper_agent_identity_fn = is_keeper_agent_identity in
  let sync_current_task_binding_fn = sync_current_task_binding in
  Task.Handlers.set_task_owner_hooks
    Task.Handlers.
      { is_keeper_agent_identity =
          (fun config ~agent_name ->
             is_keeper_agent_identity_fn config ~agent_name)
      ; sync_current_task_binding =
          (fun config ~agent_name -> sync_current_task_binding_fn config ~agent_name)
      }
;;
