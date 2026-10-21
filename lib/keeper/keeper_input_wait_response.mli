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


(** Original Owner maintenance authority and sealed physical response receipt. *)
type authority
type receipt
type installation_error =
  | Invalid_response of string
  | Retained_unavailable of Keeper_checkpoint_store.checkpoint_cas_error
  | Canonical_unavailable of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Response_refused of refusal
  | Installation_unconfirmed of Keeper_checkpoint_store.checkpoint_installation
val authorize : session_root:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  waiting:Keeper_semantic_execution.input_wait -> authority
(** A caller-created authority cannot match the one captured by its Owner. *)
val waiting : authority -> Keeper_semantic_execution.input_wait
val install : net:Eio_context.eio_net -> authority:authority ->
  response:Agent_core.Hooks.elicitation_response -> (receipt, installation_error) result
(** Under the original exclusive maintenance child, verify exact retained input
    and canonical request/scope/history, derive the Core response using the
    canonical question, update a validated existing derived message_count to the
    consumed history length, retain frozen bytes, then CAS canonical installation.
    Missing/corrupt/diverged canonical requires reconciliation. Filesystem and
    SQLite commits are separate. No failure mints a receipt or retry authority. *)
val belongs_to : receipt -> authority -> bool
val installed_checkpoint : receipt -> Keeper_checkpoint_ref.t
val installation_error_to_string : installation_error -> string
