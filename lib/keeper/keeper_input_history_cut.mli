(** Exact incomplete-Assistant history reduction, separate from admission. *)
type t
type binding
val prepare : source:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  candidate:Agent_core.Checkpoint.t -> (t, string) result
(** Remove only the final Assistant message without ToolResult, preserving every
    other checkpoint field except creation time. Pending input must be absent;
    this transformation cannot consume an answer or discard a waiting request. *)
val source_checkpoint : t -> (Agent_core.Checkpoint.t, string) result
val cut_checkpoint : t -> (Agent_core.Checkpoint.t, string) result
val validate_candidate : t -> Agent_core.Checkpoint.t option -> (unit, string) result
val bind_seed : t -> seed:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  (binding, string) result
(** The actual next native seed must retain all cut messages and pending=None.
    A binding is immutable; mutable context values never carry its authority. *)
val checkpoint : binding -> Keeper_checkpoint_ref.t
val source_reference : binding -> Keeper_checkpoint_ref.t
val validate_publication : binding -> observed_source:Keeper_checkpoint_ref.t ->
  call:Keeper_native_call.t -> (unit, string) result
(** Match the exact cut source and next native seed. This alone does not prove
    that a distinct retired native N owns a host source H; the original Owner
    must revalidate retained N-to-H preservation before branch publication. *)
val validate_native : binding -> observed:Keeper_native_call.state ->
  call:Keeper_native_call.t -> (unit, string) result
(** Require the exact retired source and exact admitted next seed. Owner must
    still validate its original child/input predecessor and compare both durable
    relations in one transaction. This proof alone grants no execution. *)
