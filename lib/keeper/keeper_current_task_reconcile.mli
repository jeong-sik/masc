(** Reconcile keeper [current_task_id] with active backlog ownership. *)

type owned_active_task = {
  task_id : Keeper_id.Task_id.t;
  task : Masc_domain.task;
}

type owned_active_tasks_snapshot =
  { tasks : owned_active_task list
  ; backlog_tasks : Masc_domain.task list
  ; backlog_version : int
  }

(** Return every Claimed/InProgress backlog task owned by [meta]'s agent
    binding. *)
val owned_active_tasks_for_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (owned_active_task list, string) result

(** Strict ownership, task records, and the backlog CAS version captured by the
    same read. The complete task snapshot lets lifecycle transactions reconcile
    their own durable receipts without racing a second backlog read. *)
val owned_active_tasks_snapshot_for_meta_strict :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (owned_active_tasks_snapshot, string) result

(** Find the deterministic active task a keeper should treat as current.

    Only [Claimed] and [InProgress] tasks are active bindings. Tasks awaiting
    verification have left the keeper's execution lane and clear the binding.
    If multiple active tasks remain, reconciliation keeps an existing active
    [current_task_id], otherwise it chooses a stable task by status, priority,
    creation time, and task id. *)
val owned_active_task_id_for_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  Keeper_id.Task_id.t option

(** The same current-task selection, preserving authoritative backlog read
    failures rather than treating them as absence. Does not change metadata. *)
val owned_active_task_id_result_for_meta :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  (Keeper_id.Task_id.t option, string) result

(** Persist [meta.current_task_id] after comparing it with backlog ownership. *)
val sync_current_task_id_from_backlog :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta

(** Best-effort reconciliation for callers that only know an agent name.
    No-ops for non-keeper agents. *)
val sync_current_task_id_for_agent_name :
  config:Workspace.config ->
  agent_name:string ->
  unit

(** Reconcile and return the same authoritative selection, including read failure.
    No second backlog read is performed when the snapshot matches. *)
val sync_current_task_id_with_observation :
  config:Workspace.config -> Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta * (Keeper_id.Task_id.t option, string) result

(** Apply a [Set_current_task] projection guarded by the authoritative backlog
    revision. Under the per-Keeper reconciliation lock, re-verifies
    [backlog_revision] and [desired] against the current prepared backlog; on a
    concurrent revision or ownership change, recomputes and applies the latest
    authoritative selection so an earlier claim projection cannot overwrite a
    later release or cancellation. Returns [Error] without mutating metadata
    when the authoritative backlog cannot be read. *)
val apply_current_task_if_revision :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?preferred_task_id:Keeper_id.Task_id.t ->
  backlog_revision:int ->
  desired:Keeper_id.Task_id.t option ->
  unit ->
  ( Keeper_id.Task_id.t option
    * (Keeper_meta_contract.keeper_meta option, Keeper_owner_registry.command_error) result
  , string ) result

(** Test seam: invoked between an initial ownership read and the serialized
    revision check + owner [Set_current_task] application in
    {!apply_current_task_if_revision}. Production leaves it at [ignore]. *)
val between_ownership_read_and_apply_hook : (unit -> unit) Atomic.t
