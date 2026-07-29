(** RFC-0356: an approval owns its effect.

    A Gate approval authorizes one exact operation identity and canonical
    complete input. Before this module, the only way that authorization
    could be spent was for the Keeper model to re-emit a byte-identical
    tool call; a non-deterministic producer cannot do that for large write
    payloads, so approved writes were never applied (#25947).

    The durable delivery entry already stores the approved input, so the
    runtime replays that stored payload directly. The canonical input is
    re-derived at execution, which keeps the pinned resource identity
    (device/inode) authoritative: a target replaced between approval and
    replay no longer matches and stays unapplied. *)

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

val repair_stage_to_string : repair_stage -> string

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
  Agent_sdk.Types.content_block list ->
  Agent_sdk.Types.content_block list
(** Append the same canonical replay reference to a structured user input.
    This keeps replay evidence live when a multimodal goal uses [goal_blocks]
    instead of the string [goal]. *)

val project_model_input :
  base_path:string ->
  model_evidence ->
  Agent_sdk.Types.message list ->
  (Agent_sdk.Types.message list, string) result
(** Append the full durable payload as an explicit provider-only message.
    Canonical history remains reference-only and no text search or replacement
    decides where evidence is attached. A storage miss is logged and leaves the
    current input unchanged, matching ordinary artifact hydration. OAS measures
    and dispatches this same projection; no Keeper byte cap or preview
    substitutes for the current result. *)

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
    canonical state and expose its exact bytes through [project_model_input]. *)

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

type replayable =
  | Replay_write
  | Replay_execute
  | Replay_network_read
  | Replay_connector_post

val replayable_of_operation : string -> replayable option
(** Which approved operations can be spent without the Keeper re-emitting the
    call. Exposed because a decode function that exists but is never dispatched
    to is indistinguishable from a working replay at the boundary. *)

(** Replay the approved effect behind [approval_id] exactly once.

    Covers operations whose approvals a Keeper must otherwise re-earn by
    re-emitting a byte-identical call: [filesystem_write], [tool_execute], and
    producer-typed [network_read] (WebSearch/WebFetch), and exact
    [connector_post] continuations. Any other operation is
    {!Not_applicable}; its existing model-issued path remains authoritative.

    [gate_context] is the same causal-context provider the model-issued write
    path supplies. A re-derived input mismatch follows that producer's existing
    ordinary Gate semantics; replay adds no second authorization constraint.

    The caller already holds [Keeper_turn_admission]'s per-Keeper turn mutex.
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

module For_testing : sig
  val persist_replay_artifact :
    base_path:string ->
    string ->
    (Tool_output.artifact_ref, string) result

  val with_replay_evidence_persister :
    ( base_path:string
      -> string
      -> (Tool_output.artifact_ref, string) result ) ->
    (unit -> 'a) ->
    'a
end
