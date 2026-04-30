(** Reconcile keeper [current_task_id] with active backlog ownership. *)

(** Find the single active task a keeper owns.

    Only [Claimed] and [InProgress] tasks are active bindings. Tasks awaiting
    verification have left the keeper's execution lane and clear the binding. *)
val owned_active_task_id_for_meta :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  Keeper_id.Task_id.t option

(** Field-level merge for [Keeper_types.write_meta_with_merge]. *)
val merge_current_task_id :
  latest:Keeper_types.keeper_meta ->
  caller:Keeper_types.keeper_meta ->
  Keeper_types.keeper_meta

(** Persist [meta.current_task_id] after comparing it with backlog ownership. *)
val sync_current_task_id_from_backlog :
  config:Coord.config ->
  Keeper_types.keeper_meta ->
  Keeper_types.keeper_meta

(** Best-effort reconciliation for callers that only know an agent name.
    No-ops for non-keeper agents. *)
val sync_current_task_id_for_agent_name :
  config:Coord.config ->
  agent_name:string ->
  unit
