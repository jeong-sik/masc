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

type outcome =
  | Not_applicable
      (** No unconsumed approval, or the approved operation is not one this
          module replays. *)
  | Applied of string  (** Opaque human-readable summary of the replay. *)
  | Failed of string

val outcome_to_string : outcome -> string

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

type replayable =
  | Replay_write
  | Replay_execute

val replayable_of_operation : string -> replayable option
(** Which approved operations can be spent without the Keeper re-emitting the
    call. Exposed because a decode function that exists but is never dispatched
    to is indistinguishable from a working replay at the boundary. *)
(** Recover the execute tool arguments from the approved Gate input. Nothing is
    reconstructed: the Gate request wraps the arguments with execution context
    rather than re-encoding them. *)

(** Replay the approved effect behind [approval_id] exactly once.

    Covers the two operations whose approvals a Keeper must otherwise re-earn
    by re-emitting a byte-identical call: [filesystem_write] and
    [tool_execute]. Any other operation is {!Not_applicable} and still
    requires resubmission.

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
