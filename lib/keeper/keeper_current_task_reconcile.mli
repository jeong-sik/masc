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

(** Shutdown transaction variant: agent-name resolution and backlog reads are
    both strict. No fallback name is guessed when ownership identity cannot be
    resolved. *)
val owned_active_tasks_for_meta_strict :
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

(** Field-level merge for [Keeper_meta_store.write_meta_with_merge]. *)
val merge_current_task_id :
  latest:Keeper_meta_contract.keeper_meta ->
  caller:Keeper_meta_contract.keeper_meta ->
  Keeper_meta_contract.keeper_meta

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
