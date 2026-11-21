(** The routes the account gate decides against, read from the router's own table.

    {!Http_server_eio.Router.Typed} records the access a registration names on
    the route, and the router exports the routes dispatch can reach
    ({!Http_server_eio.Router.effective_routes}). This module reads that table
    instead of parsing registration sites, so the inventory cannot drift from
    what dispatch actually answers: a route registered through a helper, a
    prefix route, and a route a later registration replaced are all seen the way
    dispatch sees them.

    A keeper sub-route is [Route_access.Subpath_dispatch]'s problem: the route
    table names the prefix and not the sub-routes, so a sub-route is covered
    when its prefix is covered. Count the sub-routes from
    [Server_dashboard_http_keeper_get_route] when a number is wanted; do not
    expect them as rows here. *)

type entry =
  { path : string
  ; kind : Http_server_eio.Router.route_kind
  ; methods : Httpun.Method.t list
  ; access : Route_access.t
  }

val of_router : Http_server_eio.Router.t -> entry list
(** [of_router router] is every route dispatch can reach, in registration
    order. Read this, not the registration sites: a path registered twice keeps
    the row dispatch uses. *)

val keeper_prefix : string
(** The prefix whose sub-routes the route table cannot name. *)

val covers : entry list -> path:string -> method_:Httpun.Method.t -> bool
(** [covers entries ~path ~method_] is true when an entry answers [path]: an
    [Exact] entry whose path is equal, or a [Prefix] entry whose path is a
    prefix of [path]. The method must be one the entry lists; a route that
    dispatches the path but not the method is not covered, because the inventory
    speaks about accesses and a method the router does not index has none. *)

val covering : entry list -> path:string -> method_:Httpun.Method.t -> entry option
(** {!covers} as the route it matched, for a caller that wants the access. *)

val keeper_prefix_present : entry list -> bool
(** Whether the keeper prefix is in the inventory as a [Prefix] entry. *)

val to_json : entry list -> Yojson.Safe.t
(** The inventory as JSON, one object per row, for an operator report. *)
