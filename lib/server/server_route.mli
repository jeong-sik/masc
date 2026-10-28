(** HTTP route registration that names the authentication each route needs.

    A route is registered with a value of {!auth}. The registration function
    applies the [Server_auth] wrapper that goes with it and stores the matching
    {!Route_access.t} on the route, so the route table says which routes are open
    without running a handler. The older functions of {!Http_server_eio.Router}
    record [Route_access.Unclassified] and are removed in the last layer of the
    stack that introduces this module (docs/rfc/RFC-typed-route-auth.md). *)

type state_handler =
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit

(** The [string] is the token id the credential resolved to. *)
type token_handler =
  Mcp_server.server_state -> string -> Httpun.Request.t -> Httpun.Reqd.t -> unit

(** The [string] is the principal that authorised the tool call, as
    [Server_auth.with_tool_actor_auth] resolves it. *)
type actor_handler =
  Mcp_server.server_state -> string -> Httpun.Request.t -> Httpun.Reqd.t -> unit

(** The type parameter is the handler the kind wraps. The handler of a kind
    that wraps nothing sees the request itself. *)
type _ auth =
  | Always_public : Http_server_eio.request_handler auth
  | Public_read : state_handler auth
  | Read_auth : state_handler auth
  | Permission : Masc_domain.permission -> state_handler auth
  | Token_permission : Masc_domain.permission -> token_handler auth
  | Private_token_permission : Masc_domain.permission -> token_handler auth
  | Tool : { tool_name : string } -> state_handler auth
  | Tool_actor : { tool_name : string } -> actor_handler auth
  | Self_authenticated :
      Route_access.self_authenticated_reason
      -> Http_server_eio.request_handler auth

(** What a route registered with this kind records. *)
val access : _ auth -> Route_access.t

val get : 'h auth -> string -> 'h -> Http_server_eio.Router.t -> Http_server_eio.Router.t
val post : 'h auth -> string -> 'h -> Http_server_eio.Router.t -> Http_server_eio.Router.t

val add
  :  'h auth
  -> path:string
  -> methods:Httpun.Method.t list
  -> 'h
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

(** The prefix functions match any path that starts with the prefix; the suffix
    is available through [Http_server_eio.Request.path]. *)
val prefix_get
  :  'h auth
  -> string
  -> 'h
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

val prefix_post
  :  'h auth
  -> string
  -> 'h
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

val prefix_put
  :  'h auth
  -> string
  -> 'h
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

val prefix_delete
  :  'h auth
  -> string
  -> 'h
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t

(** A WebSocket-upgrade route. The handler checks the credential before it
    upgrades, so the only kind that applies is [Self_authenticated
    Websocket_upgrade]. *)
val ws_get
  :  string
  -> Http_server_eio.Router.ws_handler
  -> Http_server_eio.Router.t
  -> Http_server_eio.Router.t
