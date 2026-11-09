(** RFC-0356: an approval owns its effect.

    A Gate approval authorizes one exact operation identity and canonical
    complete input. Before this module, the only way that authorization
    could be spent was for the Keeper model to re-emit a byte-identical
    tool call; a non-deterministic producer cannot do that for large write
    payloads, so approved writes were never applied (#25947).

    The durable delivery entry already stores the approved input, so the
    runtime replays that stored payload directly. At execution, the producer
    re-derives its canonical input and applies its ordinary Gate exact-match
    semantics. Only resource identities that the producer includes are pinned:
    filesystem atomic replace pins the root and parent capabilities, append
    additionally pins the existing target, and patch additionally pins its
    source. Atomic replace authorizes replacing the named directory entry and
    does not pin the prior target inode. *)

type replay_journal =
  | Replay_journal_recorded
  | Replay_journal_already_recorded
  | Replay_grant_not_consumed

type repair_stage =
  | Resolution_lookup
  | Request_decode
  | Evidence_storage
  | Evidence_retrieval
  | Replay_journal
  | Stale_grant_retirement
  | Invalid_resolution_state

type outcome =
  | Not_applicable
      (** The approved operation has no producer-owned host replay
          continuation and retains its existing model-issued path. *)
  | Applied of
      { operation : string
      ; output_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Applied_with_warning of
      { operation : string
      ; detail_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Failed of
      { operation : string
      ; detail_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
  | Indeterminate of
      { operation : string
      ; detail_ref : Tool_output.artifact_ref
      ; journal : replay_journal
      }
      (** The effect may already have happened. This is a durable terminal
          outcome and is never eligible for replay. *)
  | Repair_required of
      { operation : string
      ; stage : repair_stage
      ; detail : string
      }
      (** Host replay cannot safely enter the provider turn. The exact wake
          remains unacknowledged. If the raw effect result still exists in
          process, later attempts repair persistence without rerunning it. *)
  | Resolution_absent of
      { absence : Keeper_approval_queue_result.resolution_absence }
      (** The durable store has no resolution behind the queued approval
          ({!Keeper_approval_queue_result.resolution_absence}): nothing can be
          replayed and reading again cannot change that. The turn proceeds
          with this told to the model once; the queue entry is retired at
          intake, so no wake stays behind it. *)

val outcome_to_string : outcome -> string
(** Render operation, journal state, exact evidence byte count, and SHA-256
    only. Full replay output is never copied into operational logs. *)

type replay_execution =
  { outcome : outcome
  ; terminal_effect_receipt :
      Keeper_tool_execution.terminal_effect_receipt option
  }
(** The outcome and its producer-owned turn-settlement receipt stay together.
    Only a successfully applied connector post carries a terminal receipt. *)

type model_evidence

type model_message = private
  { text : string
  ; resolutions : Keeper_event_queue.hitl_resolution list
      (** Every observed resolution, including repair/absence states that
          produce neither canonical evidence nor an exact-call instruction. *)
  ; replay_evidence : model_evidence list
  ; instruction_resolutions : Keeper_event_queue.hitl_resolution list
  ; approval_input_bindings :
      (Keeper_chat_delivery_identity.approval_input_binding list, string) result
      (** Prepared canonical input identities, in source order. Replay inputs
          exclude execution/recovery journal disposition; singleton notices
          identify their own rendered fragment without the base user cue.
          These are neither admission witnesses nor provider wire-byte hashes.
          Failure drops optional tool projection and never grants replay/ACK. *)
  }
(** Each resolution keeps its own evidence identity. The text contains the
    original user input once; a list grants neither replay nor queue ACK
    authority. Canonical admission and provider projection must preserve every
    evidence item in this order. *)

type resolution_input

type resolution_input_error =
  | Replay_approval_mismatch of { resolution_id : string; replay_id : string }
  | Replay_for_rejected_resolution of string

val resolution_input_error_to_string : resolution_input_error -> string

val resolution_input :
  resolution:Keeper_event_queue.hitl_resolution ->
  replay_delivery:(string * replay_execution) option ->
  (resolution_input, resolution_input_error) result
(** Bind one observed resolution to its own host replay outcome. A replay
    for a different approval or a rejected resolution is refused; two lists
    cannot be joined by their positions. No grant is created or consumed. *)

val input_resolution : resolution_input -> Keeper_event_queue.hitl_resolution
val input_replay_execution : resolution_input -> replay_execution option
(** Read-only projections of one bound input; its source, outcome and terminal
    receipt cannot be assigned to another approval by parallel list position. *)

val append_model_evidence :
  approval_id:string -> user_message:string -> outcome -> model_message
(** Append a typed artifact reference to canonical model state. The exact
    payload is deliberately absent from [text] and is available only through
    [replay_evidence]. *)

val append_model_evidence_block :
  model_evidence ->
  Agent_core.Types.content_block list ->
  Agent_core.Types.content_block list
(** Append the same canonical replay reference to a structured user input.
    This keeps replay evidence live when a multimodal goal uses [goal_blocks]
    instead of the string [goal]. *)

(** Stable canonical input and identity from the durable result. Replay
    journal disposition is deliberately excluded: recovery is the same input. *)
val approval_input : model_evidence ->
  (Keeper_approval_input_admission.identity * Agent_core.Types.message,
   Keeper_approval_input_admission.error) result

val project_model_input :
  base_path:string ->
  model_evidence ->
  Agent_core.Types.message list ->
  (Agent_core.Types.message list, Agent_core.Error.t) result
(** Append the canonical typed artifact reference as an explicit provider-only
    message. Exact replay bytes remain in durable storage and are read through
    [keeper_artifact_read], so replay evidence cannot bypass provider-input
    windowing. *)

val project_model_inputs :
  base_path:string ->
  model_evidence list ->
  Agent_core.Types.message list ->
  (Agent_core.Types.message list, Agent_core.Error.t) result
(** Restore ordered evidence in a provider-only view. Intact surviving inputs
    anchor missing predecessors immediately before them; missing successors
    are appended after the retained view. Existing messages remain in place.
    Duplicate or reversed surviving evidence is refused rather than silently
    changing the causal order. Canonical history is never rewritten. *)

val approved_resolution_message :
  approval_id:string ->
  tool_name:string ->
  input:Yojson.Safe.t ->
  user_message:string ->
  string
(** Render an unconsumed approval. Replayable operations tell the model that
    missing host evidence requires repair. Non-replayable operations retain
    the existing exact-call authorization and exact input without adding a
    second replay restriction. *)

val user_message_with_hitl_resolution :
  base_path:string ->
  user_message:string ->
  Keeper_event_queue.hitl_resolution option ->
  model_message
(** Render a durable HITL resolution that was not freshly replayed in this
    setup. Consumed approvals keep the typed content-addressed reference in
    canonical state. *)

val compose_model_message :
  base_path:string ->
  user_message:string ->
  inputs:resolution_input list ->
  model_message
(** Build the model message once, after host replay, in input order. Every
    input appends only its own current instruction or result to the accumulated
    text. A fresh replay never retains its pre-replay exact approval payload.
    Canonical history/checkpoints keep each independent artifact reference. *)

type replayable = Keeper_gate.replayable
(** Which approved operations can be spent without the Keeper re-emitting the
    call. Owned by the Gate ({!Keeper_gate.replayable_operation}) so the
    deferred payload's on_approve promise and this engine's dispatch answer
    to one definition — a promise the engine cannot keep starves the
    approved effect silently (#32668). Exposed because a decode function
    that exists but is never dispatched to is indistinguishable from a
    working replay at the boundary. *)

val replayable_of_operation : string -> replayable option

(** Replay the approved effect behind [approval_id] exactly once.

    Covers operations whose approvals a Keeper must otherwise re-earn by
    re-emitting a byte-identical call: [filesystem_write], [tool_execute], and
    producer-typed [network_read] (WebSearch/WebFetch), exact
    [connector_post] continuations. Any other operation is {!Not_applicable};
    its existing model-issued path remains authoritative.

    [gate_context] is the same causal-context provider the model-issued write
    path supplies. A re-derived input mismatch follows that producer's existing
    ordinary Gate semantics; replay adds no second authorization constraint.

    The caller already runs in the Keeper Owner child.
    Replay does not add an approval claim or workspace-wide backpressure Gate.
    Consumption is the durable one-shot grant. A repeated call after a
    successful replay returns the durable outcome without invoking the effect.
    Consumed-without-outcome after restart is durably settled as
    {!Indeterminate}; the effect is never run again and the wake can advance. *)
val replay_approved_effect :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  grant:Keeper_gate.cycle_grant ->
  approval_id:string ->
  unit ->
  outcome

val replay_approved_effect_with_receipt :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  grant:Keeper_gate.cycle_grant ->
  approval_id:string ->
  unit ->
  replay_execution
(** Replay exactly once and retain the typed connector-post receipt needed by
    turn finalization. [replay_approved_effect] is the outcome-only projection
    for callers that do not own a turn boundary. *)

val replay_resolution_inputs :
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  publication_recovery:Keeper_publication_recovery_availability.turn_context ->
  turn_sandbox_factory:Keeper_sandbox_factory.t option ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  Keeper_hitl_resolution_batch.t ->
  resolution_input list
(** Serial host replay in frozen source order. Each approval spends only its
    own grant and uses its own captured continuation channel. A repair stops
    before later effects, returning the completed prefix and repair input;
    the caller must refuse provider dispatch and retain all wakes. The same
    turn's runtime fallback recovers this vector rather than selecting anew.
    A multiple cohort cannot fall back to a representative provider grant or
    acquire a terminal connector receipt. Cancellation propagates unchanged. *)

module For_testing : sig
  val persist_replay_artifact :
    base_path:string ->
    string ->
    (Tool_output.artifact_ref, string) result

  val settle_pre_effect_failure :
    base_path:string ->
    approval_id:string ->
    operation:string ->
    detail:string ->
    (replay_execution, string) result

  val with_replay_evidence_persister :
    ( base_path:string
      -> string
      -> (Tool_output.artifact_ref, string) result ) ->
    (unit -> 'a) ->
    'a
end
