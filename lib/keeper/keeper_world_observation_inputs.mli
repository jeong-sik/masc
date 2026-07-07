(** Input query helpers for keeper world observation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val backlog_updated_since_last_scheduled_autonomous
  :  meta:keeper_meta
  -> backlog:Masc_domain.backlog
  -> bool

val read_backlog_counts
  :  config:Workspace.config
  -> meta:keeper_meta
  -> int * int * int * int * bool

val read_current_task
  :  config:Workspace.config
  -> meta:keeper_meta
  -> Masc_domain.task option
(** Resolve [meta.current_task_id] to its backlog record (RFC-0314). [None]
    when the keeper holds no task, the id is absent from the backlog, or the
    backlog read fails (failure is logged and counted, never raised). *)

val count_running_keeper_fibers : config:Workspace.config -> int
(** Count live keeper fibers for [config.base_path].

    This intentionally does not read the legacy [.masc/agents/] registry; that
    registry may be empty while keeper fibers are healthy and running. *)
val compute_idle_seconds : meta:keeper_meta -> int
val read_context_ratio : config:Workspace.config -> meta:keeper_meta -> float
