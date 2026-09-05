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
      { absence : Keeper_approval_queue.resolution_absence }
      (** The durable store has no resolution behind the queued approval
          ({!Keeper_approval_queue.resolution_absence}): nothing can be
          replayed and reading again cannot change that. The turn proceeds
          with this told to the model once; the queue entry is retired at
          intake, so no wake stays behind it. *)

val outcome_to_string : outcome -> string
(** Render operation, journal state, exact evidence byte count, and SHA-256
    only. Full replay output is never copied into operational logs. *)

type model_evidence

type model_message =
  { text : string
  ; replay_evidence : model_evidence option
  }

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

val project_model_input :
  base_path:string ->
  model_evidence ->
  Agent_core.Types.message list ->
  (Agent_core.Types.message list, Agent_core.Error.t) result
(** Append the canonical typed artifact reference as an explicit provider-only
    message. Exact replay bytes remain in durable storage and are read through
    [keeper_artifact_read], so replay evidence cannot bypass provider-input
    windowing. *)

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
  hitl_resolution:Keeper_event_queue.hitl_resolution option ->
  replay_delivery:(string * outcome) option ->
  model_message
(** Build the model message once, after host replay. A fresh replay starts from
    the undecorated user message, so the pre-replay exact approval payload
    cannot survive beside a consumed result. Canonical history/checkpoints keep
    only the artifact reference. *)

type replayable = Keeper_gate.replayable
(** Which approved operations can be spent without the Keeper re-emitting the
    call. Owned by the Gate ({!Keeper_gate.replayable_operation}) so the
    deferred payload's on_approve promise and this engine's dispatch answer
    to one definition — a promise the engine cannot keep starves the
    approved effect silently (#32668). Exposed because a decode function
    that exists but is never dispatched to is indistinguishable from a
    working replay at the boundary. *)

val replayable_of_operation : string -> replayable option

type replay_execution =
  { outcome : outcome
  ; terminal_effect_receipt :
      Keeper_tool_execution.terminal_effect_receipt option
  }
(** The durable replay outcome plus the turn-settlement receipt owned by a
    successfully applied connector post. Other replayable operations and
    unapplied or indeterminate connector effects carry [None]. *)

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
