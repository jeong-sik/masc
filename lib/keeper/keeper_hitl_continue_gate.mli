(** Exact-identity lifecycle for partial-commit and reconcile HITL gates. *)

type decision =
  | Approve
  | Reject

val generate_id : unit -> string

val owns :
  gate_id:string -> Keeper_meta_contract.keeper_meta -> bool

val install :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  gate_id:string ->
  origin:Keeper_latched_reason.continue_gate_origin ->
  committed_tools:string list ->
  (Keeper_meta_contract.keeper_meta, string) result
(** Persist a typed pause before an in-memory approval is queued. Existing
    operator, repository, dead, or different continue-gate ownership wins. *)

val migrate_legacy :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  gate_id:string ->
  origin:Keeper_latched_reason.continue_gate_origin ->
  committed_tools:string list ->
  (Keeper_meta_contract.keeper_meta, string) result
(** Claim only a legacy [paused=true; latched_reason=None] reconcile pause.
    Any typed owner that appears during the CAS race wins. *)

val resolve :
  config:Workspace.config ->
  keeper_name:string ->
  gate_id:string ->
  decision:decision ->
  (Keeper_meta_contract.keeper_meta, string) result
(** Resolve only the exact gate. Concurrent replacement or a dead tombstone is
    returned as an error and its control fields remain authoritative. *)
