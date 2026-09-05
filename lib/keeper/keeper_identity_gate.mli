(** The durable Gate, standing in front of attached outside services.

    Every call a Keeper makes through an identity-attached provider (Jira,
    Slack, GitHub over MCP) is an external effect. Before this module, none
    of them reached {!Keeper_gate}: the only two approval devices each
    covered a different half of the runtime, and the write path to somebody
    else's service ran between them (incident of 2026-08-27: one
    keeper, three unapproved Jira tickets).

    The producer contract mirrors the built-in tools:

    - one closed opaque operation identity, {!gate_operation} — the Gate
      never parses provider or tool names, and the replay dispatch stays an
      exact match over a closed set;
    - the complete concrete input, {!gate_input} — provider id, remote tool
      name, and the arguments verbatim;
    - the inversion, {!replay_of_gate_input} — this producer owns both the
      argument schema and the effect encoding, so it owns the decode.

    Routing is the provider's own written word: a tool whose catalog row
    says [read_only = Some true] runs unasked; [Some false] and silence both
    go to the Gate on the external-services lane
    ({!Keeper_gate.decide_external_service}). *)

val gate_operation : string

val gate_input :
  provider_id:string ->
  remote_name:string ->
  arguments:Yojson.Safe.t ->
  Yojson.Safe.t

type replay_call = {
  input : Yojson.Safe.t;  (** the approved input, kept verbatim *)
  provider_id : string;
  remote_name : string;
  arguments : Yojson.Safe.t;
}

val replay_of_gate_input : Yojson.Safe.t -> (replay_call, string) result
(** Strict: every field exactly once, unknown fields rejected, blank ids
    rejected. An approval that cannot be decoded is repaired, not guessed. *)

val call_summary : replay_call -> string option
(** The one line an identity_call approval is about: the provider surface it
    would reach, as [provider_id/remote_name]. This is the identity tool's
    declared call summary; the submitting path and the replay engine both
    state it through this function. The arguments are the remote tool's
    payload and take no part in it. *)

val agent_tool :
  ?post:Mcp_client.post ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  Keeper_identity_tools.offered_tool ->
  Agent_core.Tool.t
(** One offered tool, made placeable in a Keeper turn.

    A read-only tool runs as before. Anything else asks the Gate first: a
    [Deferred] decision comes back to the model as the same deferred payload
    the built-in tools use — the call did not run, the Keeper keeps living,
    and the host replays the exact call once it is approved. [gate_grant] is
    the cycle's one-shot resolution, threaded so a byte-identical re-emission
    inside the woken cycle can also spend it. *)

val replay_call_with_outcome :
  ?post:Mcp_client.post ->
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  gate_grant:Keeper_gate.cycle_grant ->
  replay_call ->
  Keeper_tool_execution.t
(** Spend one approval by running the approved call from its stored input.

    The stored input goes back through the same Gate on the same lane, so
    the exact match consumes the durable one-shot grant and a mismatch
    follows the ordinary Gate. Effect disposition is honest about the wire:
    a session that never came up, a refused token, or a request the server
    rejected before execution prove no effect; any failure after the call
    was sent is an unknown outcome, never retried. *)
