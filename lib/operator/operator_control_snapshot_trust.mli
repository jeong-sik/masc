(** Runtime-trust JSON helpers for operator control snapshots. *)

val compact_keeper_runtime_trust_observation :
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta ->
  Dashboard_projection_read.observation
(** Actual Current summary and its original typed read completeness. *)

val compact_keeper_runtime_trust_json :
  read_policy:Dashboard_projection_read.t ->
  config:Workspace.config -> meta:Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** [Current] reads the actual uncached summary. [Reuse] permits the compact
    projection cache for ordinary requests. *)
