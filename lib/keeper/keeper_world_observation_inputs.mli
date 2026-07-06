(** Input query helpers for keeper world observation. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile

val backlog_updated_since_last_scheduled_autonomous
  :  meta:keeper_meta
  -> backlog:Masc_domain.backlog
  -> bool

type backlog_counts = int * int * int * int * bool

val read_backlog_counts_result
  :  config:Workspace.config
  -> meta:keeper_meta
  -> (backlog_counts, string) result

val read_backlog_counts
  :  config:Workspace.config
  -> meta:keeper_meta
  -> backlog_counts

val count_running_keeper_fibers : config:Workspace.config -> int
(** Count live keeper fibers for [config.base_path].

    This intentionally does not read the legacy [.masc/agents/] registry; that
    registry may be empty while keeper fibers are healthy and running. *)
val compute_idle_seconds : meta:keeper_meta -> int
val read_context_ratio : config:Workspace.config -> meta:keeper_meta -> float
