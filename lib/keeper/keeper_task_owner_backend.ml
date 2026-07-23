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

let active_goal_phases_for_agent config ~agent_name =
  match Keeper_meta_store.read_meta_resolved config agent_name with
  | Ok (Some (_, meta)) ->
    List.map
      (fun goal_id ->
         match Goal_store.get_goal config ~goal_id with
         | Some goal -> Printf.sprintf "%s=%s" goal_id (Goal_phase.to_string goal.phase)
         | None -> Printf.sprintf "%s=missing" goal_id)
      meta.active_goal_ids
  | Ok None | Error _ -> []
;;
let install_hooks () =
  let is_keeper_agent_identity_fn = is_keeper_agent_identity in
  let sync_current_task_binding_fn = sync_current_task_binding in
  let active_goal_phases_for_agent_fn = active_goal_phases_for_agent in
  Task.Handlers.set_task_owner_hooks
    Task.Handlers.
      { is_keeper_agent_identity =
          (fun config ~agent_name ->
             is_keeper_agent_identity_fn config ~agent_name)
      ; sync_current_task_binding =
          (fun config ~agent_name -> sync_current_task_binding_fn config ~agent_name)
      ; active_goal_phases_for_agent =
          (fun config ~agent_name -> active_goal_phases_for_agent_fn config ~agent_name)
      }
;;
