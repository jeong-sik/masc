(** Durable semantic lifetime of one autonomous invocation. Queue membership
    and checkpoint payloads are projections; this record owns continuation. *)
type source_member = private
  { post_id : string
  ; admitted_revision : int64
  ; checkpoint_retentions : int
  ; source_sha256 : string
  }
val source_member :
  post_id:string -> admitted_revision:int64 -> checkpoint_retentions:int ->
  source_sha256:string -> (source_member, string) result

type source_projection = private
  { original : source_member
  ; observed : source_member
  ; bound_scope : Keeper_execution_scope_id.t
  }
val source_projection : original:source_member -> observed:source_member ->
  bound_scope:Keeper_execution_scope_id.t -> (source_projection, string) result
(** Caller re-reads the selected queue entry and verifies its durable binding.
    The original admission stays immutable when queue priority/revision changes. *)
type terminal = Completed | Cancelled | Failed of string
type recovery_origin =
  | Unconfirmed_sources
  | Confirmed_undispatched
  | Checkpointed of Keeper_checkpoint_ref.t
  | Interrupted_execution
type recovery = { origin : recovery_origin; diagnostic : string }
type phase =
  | Preparing
  | Ready
  | Running
  | Recovering of recovery
  | Suspended of Keeper_checkpoint_ref.t
  | Settled of terminal

type t = private
  { id : Uuidm.t
  ; revision : int64
  ; sources : source_member list
  ; current_sources : source_member list
  ; frame : Keeper_repetition_snapshot.t
  ; phase : phase
  ; created_at : float
  ; updated_at : float
  }
type error =
  | Invalid_record of string
  | Invalid_transition of string
  | Revision_exhausted

type action =
  | Confirm_sources
  | Begin_execution
  | Recheck_sources of source_projection list
  | Resume_checkpoint of Keeper_checkpoint_ref.t
  | Record_observation of Keeper_repetition_snapshot.observation
  | Require_reconciliation of string
  | Suspend of Keeper_checkpoint_ref.t
  | Settle of terminal

val error_to_string : error -> string
val phase_name : phase -> string
val is_terminal : t -> bool
val scope : t -> Keeper_execution_scope_id.t
val create : id:Uuidm.t -> sources:source_member list -> now:float -> (t, error) result
val apply : now:float -> action -> t -> (t, error) result
(** Recheck_sources carries a complete, caller-verified projection of the
    original batch's current queue entries and their durable scope bindings.
    It recovers only undispatched phases; new generations retain initial
    membership and update current_sources without resetting the frame.

    Resume_checkpoint requires that the caller re-read and validate the exact
    canonical checkpoint named by Suspended/Checkpointed. The journal owns
    this accepted continuation, so original attention may already be ACKed.
    Cancellation must settle this journal before withdrawing its queue source.

    Interrupted_execution has no automatic resume action. Neither an empty
    frame nor checkpoint presence proves a session/effect reconciliation.
    That future transition needs an actual adapter-owned witness. Repeated
    identical Require_reconciliation preserves origin and returns the same
    record without spending a revision. *)
val same_admission : t -> t -> bool
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
