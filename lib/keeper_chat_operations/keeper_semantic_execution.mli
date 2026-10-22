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

type runtime_retry = private
  { checkpoint : Keeper_checkpoint_ref.t
  ; assignment_id : string
  ; failed_runtime_id : string
  ; next_runtime_id : string
  ; later_runtime_ids : string list
  ; not_before : float option
      (** Earliest wall-clock time at which the retry becomes claimable again.
          [Some] is set when the deferring failure was the provider throttling
          (rate limit, hard quota, provider capacity); [None] keeps the
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
val runtime_suffix : assignment_id:string -> failed_runtime_id:string -> next_runtime_id:string -> later_runtime_ids:string list -> (runtime_suffix, string) result
type official_client_kind = Codex | Claude_code | Antigravity | Muse
val official_client_kind_to_string : official_client_kind -> string
(** The wire spelling every store and projection writes for a kind. *)
val official_client_kind_of_string : string -> official_client_kind option
(** [None] for any spelling {!official_client_kind_to_string} does not emit. *)
type official_client_checkpoint =
  { client_kind : official_client_kind; runtime_id : string; session_id : string;
    turn_id : string; tool_surface_sha256 : string; frame : Keeper_repetition_snapshot.t }
type gate_checkpoint = Agent_core of Keeper_checkpoint_ref.t | Official_client of official_client_checkpoint
val equal_gate_checkpoint : gate_checkpoint -> gate_checkpoint -> bool
type gate_wait = private
  { checkpoint : gate_checkpoint; obligations : gate_obligation list; runtime_retry : runtime_retry option }
val gate_wait : checkpoint:Keeper_checkpoint_ref.t -> obligations:gate_obligation list ->
  (gate_wait, string) result
val official_client_gate_wait : checkpoint:official_client_checkpoint ->
  obligations:gate_obligation list -> (gate_wait, string) result
val gate_wait_with_runtime_retry : checkpoint:Keeper_checkpoint_ref.t -> obligations:gate_obligation list ->
  runtime_retry:runtime_retry -> (gate_wait, string) result
type gate_preparation =
  | Prepared_agent_core of { reference : Keeper_checkpoint_ref.t; canonical_checkpoint_bytes : string }
  | Prepared_official_client of official_client_checkpoint
val preparation_checkpoint : gate_preparation -> gate_checkpoint
type gate_binding = private { approval_ids:string list; obligations:gate_obligation list; runtime_suffix:runtime_suffix option; unconfirmed_wait:gate_wait option; preparation:gate_preparation }
val gate_binding : preparation:gate_preparation -> approval_ids:string list -> obligations:gate_obligation list -> runtime_suffix:runtime_suffix option -> (gate_binding, string) result
type gate_decision = Gate_approved | Gate_denied of string
type gate_resolution = { obligation : gate_obligation; decision : gate_decision }
type gate_wait_state = { waiting : gate_wait; resolution : gate_resolution option }
val equal_gate_wait : gate_wait -> gate_wait -> bool
val gate_binding_with_wait : binding:gate_binding -> waiting:gate_wait -> (gate_binding, string) result
type input_wait = private
  { checkpoint : Keeper_checkpoint_ref.t
  ; pending : Agent_core.Agent_input_request.pending }
val input_wait : checkpoint:Keeper_checkpoint_ref.t ->
  pending:Agent_core.Agent_input_request.pending -> (input_wait, string) result
val equal_input_wait : input_wait -> input_wait -> bool
(** Exact owned input and complete canonical request. The serialized request is
    validated; this value alone is not filesystem or response authority. The
    Owner must read and compare its exact retained payload before admission. *)
type input_response_destination = Canonical_input | Operation_input
type input_response_intent = private
  { waiting : input_wait
  ; source : Keeper_checkpoint_ref.t
  ; candidate : Keeper_checkpoint_ref.t
  ; response : Agent_core.Hooks.elicitation_response
  ; destination : input_response_destination }
val canonical_input_response : Agent_core.Hooks.elicitation_response ->
  (Agent_core.Hooks.elicitation_response, string) result
(** Canonicalize Answer JSON recursively before deriving a physical candidate
    or recording an intent; reject duplicate keys and non-finite numbers.
    Declined and Timeout remain distinct responses. *)
val input_response_intent : waiting:input_wait -> source:Keeper_checkpoint_ref.t ->
  candidate:Keeper_checkpoint_ref.t -> response:Agent_core.Hooks.elicitation_response ->
  destination:input_response_destination ->
  (input_response_intent, string) result
val equal_input_response_intent : input_response_intent -> input_response_intent -> bool
(** The original complete wait, canonical source and frozen consumed candidate.
    All references share the wait's trace; the source may extend its history,
    and the candidate preserves the source's turn. Answers are canonical JSON.
    This value validates identity structure, not physical payloads, installation,
    response acceptance or continuation authority. *)
val continues_input_response_intent : previous:input_response_intent ->
  next:input_response_intent -> bool
(** Preserve the exact W/S/C and complete response. The destination can stay
    unchanged or advance from Canonical_input to Operation_input when a newer
    independent input must be preserved. It can never reattach a branch or
    change any other fact. The caller must independently validate the current
    Owner and storage destination; this comparison grants no physical authority. *)
type input_branch = private
  { origin : input_wait
  ; checkpoint : Keeper_checkpoint_ref.t }
(** A direct operation's independent input lineage. [origin] is its first
    complete wait and never changes; [checkpoint] is its current retained input
    head, including a later pending request. This is independent of the trace's
    global input head and survives consuming a phase-specific continuation.
    Reference identity is not physical payload or dispatch authority. *)
type terminal = Completed | Cancelled | Failed of string
type recovery_origin =
  | Unconfirmed_sources
  | Confirmed_undispatched
  | Checkpointed of Keeper_checkpoint_ref.t
  | Official_checkpointed of official_client_checkpoint
  | Interrupted_execution
  | Runtime_retry of runtime_retry
  | Gate_wait of gate_wait_state
  | Gate_binding of gate_binding
  | Input_wait of input_wait
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
  ; native_call : Keeper_native_call.state
  ; input_response_intent : input_response_intent option
  ; input_branch : input_branch option
  ; canonical_input_origin : input_wait option
      (** Original response lineage while this execution still follows the
          global input. A different publisher atomically detaches it before
          replacing global input; this is not a prepared response intent. *)
  ; created_at : float
  ; updated_at : float
  }
type error =
  | Invalid_record of string
  | Invalid_transition of string
  | Native_call_unsettled
      (** The execution's native call blocks the requested change. Either it is
          active and its terminal disposition has not been recorded, so settling
          or changing the phase is refused, or it holds an unknown-effect
          receipt, which cannot complete or resume through another
          continuation. Both are reachable preconditions, not a damaged
          record. *)
  | Revision_exhausted

type action =
  | Confirm_sources
  | Begin_execution
  | Resume_checkpoint of Keeper_checkpoint_ref.t
  | Resume_official_checkpoint of official_client_checkpoint
  | Require_reconciliation of string
  | Suspend of Keeper_checkpoint_ref.t
  | Suspend_official_checkpoint of official_client_checkpoint
  | Suspend_runtime_retry of runtime_retry
  | Resume_runtime_retry of runtime_retry
  | Update_runtime_retry_wait of { observed : runtime_retry; replacement : runtime_retry }
  | Suspend_gate_reconciliation of gate_binding * string
  | Suspend_gate of gate_wait
  | Suspend_input of input_wait
  | Prepare_input_response of input_response_intent
  | Resolve_input of { observed : input_wait; checkpoint : Keeper_checkpoint_ref.t }
  | Resolve_input_branch of { observed : input_wait; checkpoint : Keeper_checkpoint_ref.t }
  | Advance_input_branch of
      { observed : Keeper_checkpoint_ref.t; checkpoint : Keeper_checkpoint_ref.t }
  | Reconcile_gate_binding of gate_binding * gate_wait
  | Resolve_gate of gate_resolution
  | Resume_gate of gate_wait * gate_resolution
  | Discharge_gate of gate_obligation
  | Settle of terminal

val error_to_string : error -> string
val checkpoint_input_branch : now:float -> observed:Keeper_checkpoint_ref.t ->
  checkpoint:Keeper_checkpoint_ref.t -> t -> (t, error) result
(** Publish a retained host checkpoint under an existing running input branch.
    Before native dispatch or after an exact Retire receipt, only the current
    turn's metadata/history may be changed: the turn is preserved. Active native
    execution permits confirmation of its already published checkpoint only.
    Unknown effects, inactive phases and a changed branch predecessor refuse.
    The caller must validate original child, retained bytes, pending ownership
    and operation scope; references alone grant no physical authority. *)
val phase_name : phase -> string
val is_terminal : t -> bool
val checkpoint_references : t -> Keeper_checkpoint_ref.t list
(** Every Agent Core checkpoint the record can still ask the store for: the
    one it resumes, a retry's, a Gate wait's and a Gate preparation's. A
    retained continuation named by no record's list is never read again. A
    direct operation's references all live directly under the session root,
    in the directory named by the reference's trace id. A branch pins both its
    historical root and current input head until semantic settlement. *)

val continuation_checkpoints : t -> Keeper_checkpoint_ref.t list
(** Current native checkpoint and phase-specific continuations, all under
    their trace directories in the session root. The immutable native admission seed is excluded;
    it is historical evidence, not the latest pending-input authority. If a
    phase independently references that same seed, its continuation remains.
    Prepared input-response source/candidate references are also excluded: they
    are recovery evidence, never ordinary pending-input or resume authority.
    A branch contributes its current input head, including between consuming
    its suspended continuation and publishing the next native call; its
    historical root is excluded. {!checkpoint_references} includes all evidence
    for cleanup. *)

val gate_approval_ids : t -> string list
(** Approval ids this execution may still read from the Gate store: the
    obligations of a Gate wait or of the wait it is resuming, and the approval
    ids and obligations of a Gate binding, plus the obligations not yet
    discharged. *)

val scope : t -> Keeper_execution_scope_id.t
val create : id:Keeper_execution_scope_id.t -> input:Yojson.Safe.t -> sources:source_member list -> now:float -> (t, error) result
(** The producer owns the input codec. Its canonical payload remains available
    during waiting/recovery and is released only at semantic settlement. The
    immutable digest remains part of admission identity after release. *)
val detach_canonical_input : now:float -> input_checkpoint:Keeper_checkpoint_ref.t ->
  t -> (t, error) result
(** Detach a response-derived canonical execution onto its exact current
    continuation before an independent publisher advances global input. Keeps
    its complete original wait and all existing native/Gate/retry authority.
    Caller owns the same SQLite transaction as that global input replacement. *)
val retain_repetition_frame : now:float -> Keeper_repetition_snapshot.t -> t -> (t, error) result
(** Retain only this original scope from a caller-validated frame. Existing
    observations must be an exact suffix of the candidate's newest-first
    observations. A different active scope, rollback or terminal execution
    refuses; equal evidence is unchanged. The Owner must validate the actual
    executing child and retained checkpoint, not only this pure projection. *)
val apply : now:float -> action -> t -> (t, error) result
(** Resume_checkpoint requires that the caller re-read and validate the exact
    canonical checkpoint named by Suspended/Checkpointed. The journal owns
    this accepted continuation, so original attention may already be ACKed.
    Cancellation must settle this journal before withdrawing its queue source.

    Interrupted_execution has no automatic resume action. Neither an empty
    frame nor checkpoint presence proves a session/effect reconciliation.
    That future transition needs an actual adapter-owned witness. Repeated
    identical Require_reconciliation preserves origin and returns the same
    record without spending a revision. Input_wait is a blocked original
    continuation, never a resumable checkpoint or a timer-expiring record.
    Suspend_input acknowledges only settled Retire native evidence together
    with the wait; generic resume and successful settlement cannot consume it.
    Prepare_input_response requires the exact original direct wait and no native
    call. It keeps that wait blocked and pins exact W/S/C/response until
    candidate resolution or cancellation/failure. Only the destination may
    advance from Canonical_input to Operation_input without changing that
    payload. Reconciliation preserves it; preparing the same complete intent
    does not spend another revision.

    [Resolve_input_branch] additionally requires that exact prepared intent's
    candidate and no native call. It atomically removes the intent, suspends on
    C and creates/advances the branch; a second response must name the branch's
    current wait and preserves its first origin. Attached [Resolve_input] cannot
    resolve a branched operation. [Advance_input_branch] requires an exact prior
    branch reference and an active native call already at the candidate, in the
    same direct operation/digest. It never changes the global input head.
    Ordinary resume/reconciliation keeps the branch; settlement removes it.
    Official-client continuations cannot carry an Agent Core input branch. *)
val update_native_call : now:float -> expected:Keeper_native_call.state ->
  replacement:Keeper_native_call.state -> t -> (t, error) result
(** Direct-operation-only CAS. A terminal call remains evidence until the
    Owner's settlement transaction resolves retirement. Unknown effects keep
    their receipt. *)
val same_admission : t -> t -> bool
val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, error) result
