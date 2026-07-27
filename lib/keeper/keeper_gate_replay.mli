(** RFC-0356: an approval owns its effect.

    A Gate approval authorizes one exact operation identity and canonical
    complete input. Before this module, the only way that authorization
    could be spent was for the Keeper model to re-emit a byte-identical
    tool call; a non-deterministic producer cannot do that for large write
    payloads, so approved writes were never applied (#25947).

    The durable delivery entry already stores the approved input, so the
    runtime replays that stored payload directly. For writes, the canonical
    input is re-derived at execution, which keeps the pinned resource identity
    (device/inode) authoritative: a target replaced between approval and replay
    no longer matches and stays unapplied. Network reads replay the exact
    approved request through the same in-process handler that serves ordinary
    model-issued calls. *)

type outcome =
  | Not_applicable
      (** No unconsumed approval, or the approved operation is not an effect
          this module replays. *)
  | Applied of string  (** Opaque human-readable summary of the replay. *)
  | Failed of string

val outcome_to_string : outcome -> string

(** Reconstruct the write tool arguments from the approved Gate input.

    The Gate input carries the resolved target under [requested_target]
    plus the payload fields; the write handler reads the same payload
    under [path]. Only fields present in the approved input are carried,
    so an approved content write never gains edit fields and vice versa. *)
val write_args_of_gate_input : Yojson.Safe.t -> (Yojson.Safe.t, string) result

type network_read_request = Keeper_tool_in_process_runtime.network_read_request =
  | Web_search of Yojson.Safe.t
  | Web_fetch of Yojson.Safe.t

val network_read_request_of_gate_input
  :  Yojson.Safe.t
  -> (network_read_request, string) result

(** Spend [grant] on the exact stored effect behind [approval_id].

    Filesystem writes retain the existing revalidation semantics. WebSearch
    and WebFetch use the stored capability input and return the handler's
    typed output to the resumed turn. Successful replay consumes the durable
    one-shot grant, so repeated delivery cannot duplicate the external
    effect. *)
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

(** Replay the approved write behind [approval_id] exactly once.

    [gate_context] is the same causal-context provider the model-issued write
    path supplies. A replay whose re-derived input no longer matches its
    approval falls back to an ordinary Gate request, and a request without
    causal context cannot be summarized for Auto Judge, which stalls the FIFO
    drain for every later approval.

    Consumption is the durable one-shot grant, so a repeated call after a
    successful replay reports {!Not_applicable} rather than writing twice. *)
val replay_approved_write :
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

val context_for_outcome : approval_id:string -> outcome -> string option
