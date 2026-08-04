(** Authenticated HTTP boundary for durable pending Keeper chat inputs.
    Inventory responses expose attachment metadata, never the stored raw
    attachment payload. *)

module Http = Http_server_eio

val operator_permission : Masc_domain.permission

val pending_get_route : string -> string option
(** Parse [/api/v1/keepers/<name>/chat/pending] exactly. *)

type pending_mutation =
  | Cancel
  | Edit
  | Move_to_end

val pending_mutation_route : string -> (string * string * pending_mutation) option
(** Parse one exact pending receipt mutation route. *)

val mutation_error_status : Keeper_chat_queue.mutation_error -> Httpun.Status.t
(** Map a {!Keeper_chat_queue.mutation_error} to the HTTP status the chat-queue
    mutation boundaries answer with. [Invalid_input] maps to
    [`Bad_request]; the six receipt-state and revision/lease mismatch
    errors map to [`Conflict]; [Persistence_not_configured],
    [Snapshot_unavailable], [Revision_exhausted] and [Persist_failed]
    map to [`Service_unavailable]. *)

val handle_get :
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  unit

val handle_cancel_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  raw_receipt_id:string ->
  string ->
  unit

val handle_mutation_post :
  Mcp_server.server_state ->
  actor:string ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_name:string ->
  raw_receipt_id:string ->
  mutation:pending_mutation ->
  string ->
  unit
