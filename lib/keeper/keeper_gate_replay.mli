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
  | Replay_journal_failed of string

type repair_stage =
  | Resolution_lookup
  | Request_decode
  | Grant_consumption
  | Evidence_storage
  | Replay_journal
  | Replay_effect_indeterminate_after_restart
  | Invalid_resolution_state

type outcome =
  | Not_applicable
      (** No unconsumed approval, or the approved operation is not one this
          module replays. *)
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
          must remain unacknowledged. When an effect outcome is still held in
          process, a later attempt repairs only blob/journal persistence and
          never invokes the effect again. *)

val repair_stage_to_string : repair_stage -> string

val outcome_to_string : outcome -> string
(** Render operation, journal state, bounded evidence byte count, and SHA-256
    only. Full replay output lives in the content-addressed tool blob store and
    is never copied into operational logs. *)

val append_model_evidence :
  approval_id:string -> user_message:string -> outcome -> string
(** Append bounded host replay evidence to the current model turn. Applied
    output is an artifact reference plus preview labelled as untrusted data,
    and both outcomes explicitly forbid blindly requesting the same approved
    operation again. An accidentally oversized value is replaced with visible
    byte-count/SHA evidence rather than copied into the request. *)

val user_message_with_hitl_resolution :
  base_path:string ->
  user_message:string ->
  Keeper_event_queue.hitl_resolution option ->
  string
(** Render a durable HITL resolution that was not freshly replayed in this
    setup. Consumed approvals expose only their durable bounded evidence. *)

val compose_model_message :
  base_path:string ->
  user_message:string ->
  hitl_resolution:Keeper_event_queue.hitl_resolution option ->
  replay_delivery:(string * outcome) option ->
  string
(** Build the model message once, after host replay. A fresh replay starts from
    the undecorated user message, so the pre-replay one-shot authorization
    cannot survive beside a consumed result. [Not_applicable] falls back to the
    durable resolution renderer for retries and non-replayable operations. *)

(** Reconstruct the write tool arguments from the approved Gate input.

    The Gate input carries the resolved target under [requested_target]
    plus the payload fields; the write handler reads the same payload
    under [path]. Only fields present in the approved input are carried,
    so an approved content write never gains edit fields and vice versa. *)
val write_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result

val execute_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result
(** Recover the execute tool arguments from the approved Gate input. Nothing is
    reconstructed: the Gate request wraps the arguments with execution context
    rather than re-encoding them. *)

val network_read_of_gate_input :
  Yojson.Safe.t ->
  (Keeper_tool_in_process_runtime.network_read_replay, string) result
(** Decode the producer-owned [network_read] envelope without reconstructing
    WebSearch or WebFetch arguments. *)

val connector_post_of_gate_input :
  Yojson.Safe.t ->
  (Keeper_tool_in_process_runtime.connector_post_replay, string) result
(** Decode the producer-owned exact connector request. *)

type replayable =
  | Replay_write
  | Replay_execute
  | Replay_network_read
  | Replay_connector_post

val replayable_of_operation : string -> replayable option
(** Which approved operations can be spent without the Keeper re-emitting the
    call. Exposed because a decode function that exists but is never dispatched
    to is indistinguishable from a working replay at the boundary. *)
(** Recover the execute tool arguments from the approved Gate input. Nothing is
    reconstructed: the Gate request wraps the arguments with execution context
    rather than re-encoding them. *)

(** Replay the approved effect behind [approval_id] exactly once.

    Covers operations whose approvals a Keeper must otherwise re-earn by
    re-emitting a byte-identical call: [filesystem_write], [tool_execute], and
    producer-typed [network_read] (WebSearch/WebFetch), and the exact durable
    [connector_post] continuation. Any other operation is {!Not_applicable}
    and still requires resubmission.

    [gate_context] is the same causal-context provider the model-issued write
    path supplies. A replay whose re-derived input no longer matches its
    approval falls back to an ordinary Gate request, and a request without
    causal context cannot be summarized for Auto Judge, which stalls the FIFO
    drain for every later approval.

    Consumption is the durable one-shot grant. A repeated call after a
    successful replay returns the already-recorded durable outcome without
    invoking the effect again. A consumed grant with no durable or in-memory
    outcome returns {!Repair_required}. *)
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
  val persist_bounded_replay_evidence :
    base_path:string -> string -> (string, string) result

  val with_replay_evidence_persister :
    (base_path:string -> string -> (string, string) result) ->
    (unit -> 'a) ->
    'a
end
