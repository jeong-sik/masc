(** Durable semantic lifetime of one producer-identified invocation. Direct
    request IDs and autonomous UUIDs retain their distinct scope constructors.
    Queue membership and checkpoint payloads are projections; this record owns
    continuation, independently of chat request delivery status. *)
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
type runtime_retry = private
  { checkpoint : Keeper_checkpoint_ref.t
  ; assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; not_before : float option
      (** Earliest wall-clock time at which the retry becomes claimable again.
          [Some] is set when the deferring failure was the provider throttling
          (rate limit, hard quota, capacity backpressure); [None] keeps the
          retry immediately claimable. Scheduling metadata only: it is not
          part of the continuation identity compared by
          {!equal_runtime_retry}. *)
  }
val runtime_retry : not_before:float option -> checkpoint:Keeper_checkpoint_ref.t -> assignment_id:string ->
  failed_runtime_id:string -> next_runtime_id:string -> later_runtime_ids:string list ->
  (runtime_retry, string) result
val equal_runtime_retry : runtime_retry -> runtime_retry -> bool
type gate_obligation = private
  { approval_id : string; tool_name : string; input_hash : string }
val gate_obligation : approval_id:string -> tool_name:string -> input_hash:string ->
  (gate_obligation, string) result
type runtime_suffix = private { assignment_id:string; failed_runtime_id:string; next_runtime_id:string; later_runtime_ids:string list }
type gate_binding = private { approval_ids:string list; obligations:gate_obligation list; runtime_suffix:runtime_suffix option }
val runtime_suffix : assignment_id:string -> failed_runtime_id:string -> next_runtime_id:string -> later_runtime_ids:string list -> (runtime_suffix, string) result
val gate_binding : approval_ids:string list -> obligations:gate_obligation list -> runtime_suffix:runtime_suffix option -> (gate_binding, string) result
type session_scope
val session_scope : string list -> (session_scope, string) result
val session_scope_components : session_scope -> string list
type official_client_kind = Codex | Claude_code | Antigravity
type official_client_checkpoint =
  { client_kind : official_client_kind; runtime_id : string; session_id : string;
    turn_id : string; tool_surface_sha256 : string; frame : Keeper_repetition_snapshot.t }
type gate_checkpoint = Agent_core of Keeper_checkpoint_ref.t | Official_client of official_client_checkpoint
type gate_wait = private
  { checkpoint : gate_checkpoint; session_scope : session_scope; obligations : gate_obligation list; runtime_retry : runtime_retry option }
val gate_wait : checkpoint:Keeper_checkpoint_ref.t -> session_scope:session_scope -> obligations:gate_obligation list ->
  (gate_wait, string) result
val official_client_gate_wait : checkpoint:official_client_checkpoint -> session_scope:session_scope ->
  obligations:gate_obligation list -> (gate_wait, string) result
val gate_wait_with_runtime_retry : checkpoint:Keeper_checkpoint_ref.t -> session_scope:session_scope -> obligations:gate_obligation list ->
  runtime_retry:runtime_retry -> (gate_wait, string) result
type gate_decision = Gate_approved | Gate_denied of string
type gate_resolution = { obligation : gate_obligation; decision : gate_decision }
type gate_wait_state = { waiting : gate_wait; resolution : gate_resolution option }
val equal_gate_wait : gate_wait -> gate_wait -> bool
type terminal = Completed | Cancelled | Failed of string
type recovery_origin =
  | Unconfirmed_sources
  | Confirmed_undispatched
  | Checkpointed of Keeper_checkpoint_ref.t
  | Interrupted_execution
  | Runtime_retry of runtime_retry
  | Gate_wait of gate_wait_state
  | Gate_binding of gate_binding
type recovery = { origin : recovery_origin; diagnostic : string }
type phase =
  | Preparing
  | Ready
  | Running
  | Resuming_runtime_retry of runtime_retry
  | Resuming_gate of gate_wait * gate_resolution
  | Recovering of recovery
  | Suspended of Keeper_checkpoint_ref.t
  | Settled of terminal

type t = private
  { id : Keeper_execution_scope_id.t
  ; revision : int64
  ; input : Yojson.Safe.t option
  ; input_sha256 : string
  ; gate_obligations : gate_obligation list
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
  | Suspend_runtime_retry of runtime_retry
  | Resume_runtime_retry of runtime_retry
  | Suspend_gate_reconciliation of gate_binding * string
  | Suspend_gate of gate_wait
  | Resolve_gate of gate_resolution
  | Resume_gate of gate_wait * gate_resolution
  | Discharge_gate of gate_obligation
  | Settle of terminal

val error_to_string : error -> string
val phase_name : phase -> string
val is_terminal : t -> bool
val scope : t -> Keeper_execution_scope_id.t
val create : id:Keeper_execution_scope_id.t -> input:Yojson.Safe.t -> sources:source_member list -> now:float -> (t, error) result
(** The producer owns the input codec. Its canonical payload remains available
    during waiting/recovery and is released only at semantic settlement. The
    immutable digest remains part of admission identity after release. *)
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
