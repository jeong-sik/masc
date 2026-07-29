(** Authenticated HTTP boundary for durable pending Keeper chat inputs. *)

module Http = Http_server_eio

val cancel_permission : Masc_domain.permission

val pending_get_route : string -> string option
(** Parse [/api/v1/keepers/<name>/chat/pending] exactly. *)

val pending_cancel_route : string -> (string * string) option
(** Parse [/api/v1/keepers/<name>/chat/receipts/<receipt>/cancel] exactly. *)

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
