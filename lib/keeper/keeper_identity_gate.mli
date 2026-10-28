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
    - the concrete input, {!gate_input} — provider id, a fingerprint of its
      endpoint and credential declaration, remote tool name, arguments,
      offered input schema and read-only hint;
    - the inversion, {!replay_of_gate_input} — this producer owns both the
      argument schema and the effect encoding, so it owns the decode.

    Every attached call goes through the external-services lane
    ({!Keeper_gate.decide_external_service}). Provider annotations are
    retained as catalog data but do not grant authority to bypass the Gate. *)

val gate_operation : string

val gate_input :
  provider:Keeper_oauth_provider.t ->
  remote_name:string ->
  arguments:Yojson.Safe.t ->
  input_schema:Yojson.Safe.t ->
  read_only:bool option ->
  Yojson.Safe.t

type replay_call = private {
  input : Yojson.Safe.t;  (** the approved input, kept verbatim *)
  provider_id : string;
  provider_authority_sha256 : string option;
  remote_name : string;
  arguments : Yojson.Safe.t;
  input_schema : Yojson.Safe.t option;
  read_only : bool option;
}

val replay_of_gate_input : Yojson.Safe.t -> (replay_call, string) result
(** Unknown fields, duplicate fields and blank ids are rejected. A recorded
    approval without a schema or provider fingerprint remains readable but
    cannot authorize a call. The fingerprint contains no credential value and
    does not prove that the account behind a credential has stayed the same. *)

val validate_replay_provider :
  provider:Keeper_oauth_provider.t -> replay_call -> (unit, string) result
(** Reject a missing or changed provider declaration, or a missing catalog
    binding, before consuming a grant or contacting the provider. *)

val call_summary : replay_call -> string option
(** The one line an identity_call approval is about: the provider surface it
    would reach, as [provider_id/remote_name]. This is the identity tool's
    declared call summary; the submitting path and the replay engine both
    state it through this function. The arguments are the remote tool's
    payload and take no part in it. *)

val agent_tool :
  ?transports:Keeper_identity_tools.transports ->
      (** A test's recorded answers. Absent in production, where the tool
          builds {!Keeper_identity_tools.http_transports} from [clock]. *)
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
      (** The turn's clock when the bundle carries one; the process clock
          ({!Eio_context.get_clock_opt}) otherwise. With neither, a call is
          refused as a precondition failure rather than made unbounded. *)
  config:Workspace.config ->
  meta:Keeper_meta_contract.keeper_meta ->
  ?continuation_channel:Keeper_continuation_channel.t ->
  ?gate_context:(unit -> Keeper_gate.causal_context) ->
  ?gate_grant:Keeper_gate.cycle_grant ->
  Keeper_identity_tools.offered_tool ->
  Agent_core.Tool.t
(** One offered tool, made placeable in a Keeper turn.

    Every call asks the Gate first: a [Deferred] decision comes back to the
    model as the same deferred payload
    the built-in tools use — the call did not run, the Keeper keeps living,
    and the host replays the exact call once it is approved. [gate_grant] is
    the cycle's one-shot resolution, threaded so a byte-identical re-emission
    inside the woken cycle can also spend it. *)

val replay_call_with_outcome :
  ?transports:Keeper_identity_tools.transports ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
      (** Resolved exactly as for {!agent_tool}: injected, else the given
          clock, else the process clock; with none the replay is refused. *)
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
    a local precondition or a session that never came up proves no effect;
    any failure after the tool request was sent has an unknown outcome and
    is not automatically retried. *)
