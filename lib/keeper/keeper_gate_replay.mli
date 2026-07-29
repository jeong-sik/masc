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
  | Replay_effect_indeterminate_after_restart
  | Invalid_resolution_state

type outcome =
  | Not_applicable
      (** The approved operation has no producer-owned host replay
          continuation and retains its existing model-issued path. *)
  | Applied of
      { operation : string
      ; output : string
      ; journal : replay_journal
      }
  | Failed of
      { operation : string
      ; detail : string
      ; journal : replay_journal
      }
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

val append_model_evidence :
  approval_id:string -> user_message:string -> outcome -> string
(** Append exact host replay evidence to the current model turn, labelled as
    untrusted data. Runtime request-body admission, not a local byte heuristic,
    owns capacity. Replay outcomes explicitly forbid blindly requesting the
    same approved operation again. [Not_applicable] leaves the message
    unchanged. *)

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
  string
(** Render a durable HITL resolution that was not freshly replayed in this
    setup. Consumed approvals rehydrate their exact replay evidence from the
    typed content-addressed reference. *)

val compose_model_message :
  base_path:string ->
  user_message:string ->
  hitl_resolution:Keeper_event_queue.hitl_resolution option ->
  replay_delivery:(string * outcome) option ->
  string
(** Build the model message once, after host replay. A fresh replay starts from
    the undecorated user message, so the pre-replay exact approval payload
    cannot survive beside a consumed result. *)

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

    Consumption is the durable one-shot grant. A repeated call after a
    successful replay returns the durable outcome without invoking the effect.
    Consumed-without-outcome after restart is {!Repair_required}. *)
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
