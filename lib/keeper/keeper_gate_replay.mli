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

val outcome_to_string : outcome -> string
(** Render operation, journal state, payload byte count, and SHA-256 only. Exact
    replay output remains in the typed outcome and durable approval journal; it
    is never copied into operational logs by this renderer. *)

val append_model_evidence :
  approval_id:string -> user_message:string -> outcome -> string
(** Append exact host replay evidence to the current model turn. Applied tool
    output is labelled as untrusted data, and both outcomes explicitly forbid
    blindly requesting the same approved operation again. *)

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

type replayable =
  | Replay_write
  | Replay_execute
  | Replay_network_read

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
    producer-typed [network_read] (WebSearch/WebFetch). Any other operation is
    {!Not_applicable} and still requires resubmission.

    [gate_context] is the same causal-context provider the model-issued write
    path supplies. A replay whose re-derived input no longer matches its
    approval falls back to an ordinary Gate request, and a request without
    causal context cannot be summarized for Auto Judge, which stalls the FIFO
    drain for every later approval.

    Consumption is the durable one-shot grant, so a repeated call after a
    successful replay reports {!Not_applicable} rather than writing twice. *)
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
