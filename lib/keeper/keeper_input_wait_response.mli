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
type plan
type receipt
type installation_error =
  | Invalid_response of string
  | Retained_unavailable of Keeper_checkpoint_store.checkpoint_cas_error
  | Canonical_unavailable of Keeper_checkpoint_store.checkpoint_ref_load_error
  | Response_refused of refusal
  | Installation_unconfirmed of Keeper_checkpoint_store.checkpoint_installation
  | Installation_mismatch of
      { retained : Keeper_checkpoint_ref.t
      ; canonical : Keeper_checkpoint_ref.t
      }
val authorize : session_root:string -> operation_id:Keeper_chat_operation.Operation_id.t ->
  waiting:Keeper_semantic_execution.input_wait ->
  destination:Keeper_semantic_execution.input_response_destination ->
  recorded:Keeper_semantic_execution.input_response_intent option -> authority
(** A caller-created authority cannot match the one captured by its Owner. *)
val waiting : authority -> Keeper_semantic_execution.input_wait
val prepare_installation : net:Eio_context.eio_net -> authority:authority ->
  response:Agent_core.Hooks.elicitation_response -> (plan, installation_error) result
(** Validate original W, source S and complete metadata/history/scope; derive C
    using Core, and freshly confirm durable retention of BOTH S and C before any
    canonical change. A recorded intent requires the same response and exact
    retained W/S/C, including rederivation of C. Only canonical S or recorded C
    can be the predecessor for Canonical_input. Operation_input derives from
    exact retained W (or recorded S), preserves canonical G without borrowing
    its history, and freshly confirms retained S/C. A recorded canonical intent
    can only be promoted with identical W/S/C/response. Reads alone grant no
    installation receipt. *)
val planned_intent : plan -> Keeper_semantic_execution.input_response_intent
val plan_belongs_to : plan -> authority -> bool
val install : plan -> (receipt, installation_error) result
(** The original Owner must first durably record this plan's exact intent under
    its same exclusive child. Install exact S->C, or recorded-intent-proven C->C
    through a fresh durable write, under the captured canonical predecessor CAS.
    Operation_input instead freshly confirms retained C, without reading or
    writing the canonical checkpoint; its receipt retains that destination.
    Filesystem and SQLite commits are separate; no failure mints a receipt or
    automatic retry authority. A caller-made authority cannot match its Owner. *)
val installed_intent : receipt -> Keeper_semantic_execution.input_response_intent
val belongs_to : receipt -> authority -> bool
val installed_checkpoint : receipt -> Keeper_checkpoint_ref.t
val installation_error_to_string : installation_error -> string
