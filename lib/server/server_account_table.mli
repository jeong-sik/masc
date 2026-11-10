(* HIGH-RISK-UNREVIEWED: what the account server of a multi-account
   installation serves. Every route of the table can be called by anyone who
   reaches the listener. *)

(** The route table of the account server ({!Server_accounts}): a router
    whose every route is of a kind that server serves.

    A route of the table is [Always_public], or it authenticates the request
    in its own code against the authorization zone
    ([Self_authenticated Browser_session]). A route of any other kind reads
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
    keep the router it was given. {!checked} judges the routes it finds, and
    {!dispatch} judges the route of each request again, so a route of another
    kind that is added after the check is not served.

    The kind is what the registration says. A handler of a served kind that
    dispatches on another router serves the routes of that router, and
    neither judgment sees them. *)

type t

(** The first route of another kind. *)
type refusal =
  { path : string
  ; access : Route_access.t
  }

val refusal_to_string : refusal -> string

(** The table that [register] fills, when every route of it is of a served
    kind. [register] gets a new router and returns it with its routes. The
    judgment names every constructor of {!Route_access.t}, so a kind that is
    added later has to be judged here before it compiles. *)
val checked
  :  (Http_server_eio.Router.t -> Http_server_eio.Router.t)
  -> (t, refusal) result

val route_count : t -> int

val is_websocket : t -> Httpun.Request.t -> bool
(** Whether the matching served route takes ownership of the connection. This read
    lets the ingress keep an upgrade on its connection domain without
    exposing the checked table's mutable router. *)

(** Answers the request from the table: the handler of its route when the
    route is of a served kind, or the 404 or the 405 of the router. A route of
    another kind, which a registration can only have added after {!checked},
    is the 404. *)
val dispatch : t -> Httpun.Request.t -> Http_reqd.t -> unit
