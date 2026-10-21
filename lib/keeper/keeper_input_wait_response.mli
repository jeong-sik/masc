(** Candidate response for an exact stored input request. This module grants
    neither current Owner authority nor permission to dispatch a continuation. *)
type t

type refusal =
  | Source_changed of Keeper_checkpoint_ref.t
  | Input_not_current of Agent_core.Agent_input_request.settlement_error
  | Input_checkpoint_failed of Agent_core.Error.t

val prepare :
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  expected_source_ref:Keeper_checkpoint_ref.t ->
  source:Keeper_checkpoint_store.exact_checkpoint_snapshot ->
  pending:Agent_core.Agent_input_request.pending ->
  response:Agent_core.Hooks.elicitation_response ->
  (t, refusal) result
(** Check the exact byte reference, then use the public Agent response owner
    check and canonical question. A temporary Agent has no provider, tools,
    checkpoint sink, journal, event bus or MCP clients. No run is dispatched.
    Only the source's [messages] and [pending_input] may change; all other
    checkpoint fields are retained verbatim. The original snapshot is untouched.

    The host must separately reconcile its live/retained continuation authority,
    admit through the exclusive Keeper Owner and commit against [source_ref]
    before reporting acceptance. Explicit decline/timeout are responses, never
    expiry inferred from elapsed time. Cancellation propagates. *)

val source_ref : t -> Keeper_checkpoint_ref.t
val checkpoint : t -> Agent_core.Checkpoint.t
