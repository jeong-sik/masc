(** Operator history clearing under an original Owner maintenance capability.
    Planning reads exact canonical and retained input bytes before any official
    session effect. Execution retains the cleared payload before canonical CAS.
    This module does not publish input ownership; the Owner must consume its
    receipt with the same original authority.
    Filesystem and SQLite commits are separate and partial evidence survives. *)
type authority
type plan
type receipt

type error =
  | Invalid_clear of string
  | Canonical_unreadable of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Retained_unavailable of Keeper_checkpoint_store.checkpoint_cas_error
  | Installation_unconfirmed of Keeper_checkpoint_store.checkpoint_installation
  | Removal_unconfirmed of Keeper_checkpoint_store.undecodable_removal_error

type history =
  | Emptied of { cleared_message_count : int; checkpoint_found : bool }
  | Removed of { checkpoint_path : string;
                 undecodable : Keeper_checkpoint_store.checkpoint_load_error }

val authorize : session_root:string -> trace_id:Keeper_id.Trace_id.t ->
  observed:Keeper_checkpoint_ref.t option -> authority
(** The Owner captures this fresh opaque identity with its original maintenance
    child and original workspace session root. A caller-created authority cannot match that captured identity. *)
val trace_id : authority -> Keeper_id.Trace_id.t
val predecessor : authority -> Keeper_checkpoint_ref.t option
val prepare : authority:authority -> session_dir:string -> preserve_system:bool ->
  (plan, error) result
(** Both canonical and retained input must have pending_input=None. An observed
    input remains authoritative when canonical is absent or undecodable; clear
    recovers from its retained payload. Fresh absent/superseded canonical remains
    without a payload; fresh undecodable canonical is removed under its lock.
    Newer/unreadable bytes and unavailable retained input are refused. The plan
    freezes its candidate bytes and exact canonical predecessor. Same-turn
    comparison accepts only an absent or valid derived session message_count;
    other context and working-context changes remain ambiguous and refused.
    The cleared payload records its new message_count before publication. *)
(** What the planned change does to the head. *)
type head_change =
  | Empties_head
  (** The head decodes. It is replaced by one whose kept messages are all
      open, on the same trace. *)
  | Removes_undecodable_head
  (** The head does not decode. It is removed, and the retained input is put
      in with its kept messages open, or nothing is. *)
  | No_head (** There is no head: the retained input goes in, or nothing changes. *)
val head_change : plan -> head_change
val execute : plan -> (receipt, error) result
(** Run only after confirmed official-session clearing. Retention and exact
    canonical installation must both be confirmed. Actual cancellation propagates,
    including post-commit auxiliary cancellation. Failure never mints a receipt.
    Retry requires a fresh explicit operator clear and a newly prepared plan. *)
val belongs_to : receipt -> authority -> bool
val checkpoint : receipt -> Keeper_checkpoint_ref.t option
val allows_turn_reset : receipt -> bool
val history : receipt -> history
val error_to_string : error -> string
