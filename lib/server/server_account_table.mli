(* HIGH-RISK-UNREVIEWED: what the account server of a multi-account
   installation serves. Every route of the table can be called by anyone who
   reaches the listener. *)

(** The route table of the account server ({!Server_accounts}): a router
    whose every route is of a kind that server serves.

    A route of the table is [Always_public], or it authenticates the request
    in its own code against the authorization zone
    ([Self_authenticated Browser_session], and [Self_authenticated Person_mcp]
    for the MCP endpoint of a person). A route of any other kind reads
    the credentials of a single user, through a wrapper of [Server_auth] or in
    its own handler.

    The type is abstract and {!checked} is its only maker. The ingress of the
    table ({!Server_http_ingress.serve_table}) takes this type, so it cannot
    be handed a router that was not checked, and the ingress of the
    single-user server ({!Server_http_ingress.serve}) takes a router, so it
    cannot be handed the table: a listener that is wired to the wrong ingress
    does not compile.

    A router is one shared table that a registration changes in place
    ({!Http_server_eio.Router.routes}), and the registration function can
    keep the router it was given. {!checked} judges the routes it finds and
    keeps a copy of the router ({!Http_server_eio.Router.copy}). Nothing
    outside this module holds the copy, so a route that is registered after
    the check is not in the table, whatever its kind, and it replaces no
    route of the table.

    The kind is what the registration says. A handler of a served kind that
    dispatches on another router serves the routes of that router, and the
    judgment does not see them. *)

type t

(** The first route of another kind. *)
type refusal =
  { path : string
  ; access : Route_access.t
  }

val refusal_to_string : refusal -> string

(** The table that [register] fills, when every route of it is of a served
    kind. [register] gets a new router and returns it with its routes, and
    the table is a copy of the router it returns. The judgment names every
    constructor of {!Route_access.t}, so a kind that is added later has to be
    judged here before it compiles. *)
val checked
  :  (Http_server_eio.Router.t -> Http_server_eio.Router.t)
  -> (t, refusal) result

val route_count : t -> int

val stays_with_connection : t -> Httpun.Request.t -> bool
(** Whether the request is handled on the domain of its connection: its
    route is a WebSocket route, whose upgrade hands the socket to the
    handler, or a [Serving] route, whose registration says its handler may
    run beside the owner's. This read lets the ingress keep such a request
    on its connection domain without exposing the checked table's router. *)

(** Answers the request from the table: the handler of its route, or the
    404 or the 405 of the router. *)
val dispatch : t -> Httpun.Request.t -> Http_reqd.t -> unit
