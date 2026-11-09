(** Observation-only history of direct native calls, including settled calls.
    Product associations come from the operation journal; events and recursive
    identities come only from Core's public projection. *)
module Projection = Agent_core.Agent.Execution_projection
module Operation_id = Keeper_chat_operation.Operation_id

type error =
  | Invalid_keeper_name of string
  | Missing_operation_store
  | Operation_store of Keeper_chat_operation_store.error
  | Invalid_limit of int
  | Unknown_call of string
  | Unknown_after_call of string
  | Runtime_unavailable
  | Filesystem_unavailable
  | Projection_failed of Projection.error

val error_to_string : error -> string
val max_calls_per_page : int

type call_page =
  { execution_operation_id : Operation_id.t
  ; calls : Keeper_native_call.history_ref list
  ; next_after_call_id : string option
      (** Present only when more calls remain. *)
  }

val list_calls : base_path:string -> keeper_name:string -> operation_id:Operation_id.t ->
  after_call_id:string option -> limit:int -> (call_page, error) result
(** A cursor must name a call of this operation's immutable execution leader.
    It is never reset to another operation or the beginning on mismatch. *)

type event_page =
  { execution_operation_id : Operation_id.t
  ; call : Keeper_native_call.history_ref
  ; page : Projection.page
  }

val read_page : base_path:string -> keeper_name:string -> operation_id:Operation_id.t ->
  call_id:string -> after:Projection.cursor option -> through:Projection.cursor option ->
  limit:int -> (event_page, error) result
(** Open the call's original trace directory, without creating it, and forward
    Core's cursor, fixed high watermark, recursive node and parent identities.
    Missing/corrupt/mismatched evidence remains a typed error. The caller must
    apply the reasoning-content authorization and redaction boundary before
    publishing any events. No fallback or recovery is performed. *)
