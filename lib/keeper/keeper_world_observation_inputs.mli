(** Input query helpers for keeper world observation. *)

open Keeper_types

val backlog_updated_since_last_scheduled_autonomous
  :  meta:keeper_meta
  -> backlog:Masc_domain.backlog
  -> bool

val read_backlog_counts
  :  allowed_tool_names:string list option
  -> config:Coord.config
  -> meta:keeper_meta
  -> int * int * int * int * bool

val count_active_agents : config:Coord.config -> int
val compute_idle_seconds : meta:keeper_meta -> int
val read_context_ratio : config:Coord.config -> meta:keeper_meta -> float
