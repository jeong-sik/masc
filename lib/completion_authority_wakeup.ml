(** Reactive wake-up after a completion authority rejects submitted evidence. *)

let wake_rejected_producer
      ~(config : Workspace_utils_backend_setup.config)
      ~producer
      ~task_id
  =
  Keeper_current_task_reconcile.sync_current_task_id_for_agent_name
    ~config
    ~agent_name:producer;
  match Keeper_identity.canonical_keeper_name_from_agent_name producer with
  | None ->
    Log.Misc.warn
      "completion authority rejection has no canonical Keeper producer task_id=%s producer=%s"
      task_id
      producer
  | Some keeper_name ->
    (match
       Keeper_registry.wakeup_running
         ~intent:Keeper_registry.Reactive_signal
         ~base_path:config.base_path
         keeper_name
     with
     | Keeper_registry.Signaled ->
       Log.Misc.info
         "completion authority rejection signaled producer Keeper task_id=%s keeper=%s"
         task_id
         keeper_name
     | Keeper_registry.Deferred_unregistered ->
       Log.Misc.warn
         "completion authority rejection producer Keeper is unregistered task_id=%s keeper=%s"
         task_id
         keeper_name
     | Keeper_registry.Deferred_not_running phase ->
       Log.Misc.warn
         "completion authority rejection producer Keeper is not running task_id=%s keeper=%s phase=%s"
         task_id
         keeper_name
         (Keeper_state_machine.phase_to_string phase)
     | Keeper_registry.Deferred_lifecycle denial ->
       Log.Misc.warn
         "completion authority rejection producer Keeper wake denied task_id=%s keeper=%s reason=%s"
         task_id
         keeper_name
         (Keeper_lifecycle_admission.autonomous_denial_to_wire denial))
