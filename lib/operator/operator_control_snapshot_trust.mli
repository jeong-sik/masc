(** Runtime-trust JSON helpers for operator control snapshots. *)

(** Result of reading a Keeper's compact runtime trust summary. *)
type read =
  | Read of Yojson.Safe.t
  | Timed_out of string

val compact_runtime_trust_cache_key :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> string

val compact_keeper_runtime_trust_observation :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  Dashboard_projection_read.observation
(** Actual Current summary and its original typed read completeness. *)

val read_compact_keeper_runtime_trust :
  read_policy:Dashboard_projection_read.t ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> read
(** [Current] reads the actual uncached summary. [Reuse] permits the compact
    projection cache for ordinary requests and distinguishes cache timeout
    envelopes from empty trust summaries. *)

val keeper_runtime_trust_observation :
  read_policy:Dashboard_projection_read.t ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  Dashboard_projection_read.observation
(** Observation for Keeper rows under [read_policy]; timed-out cache reads
    yield [`Null] and [Partial]. *)
