(** HTTP route registration that names the authentication each route needs.

    A route is registered with a value of {!auth}. The registration function
    applies the [Server_auth] wrapper that goes with it and stores the matching
    {!Route_access.t} on the route, so the route table says which routes are open
    without running a handler. The router does not export a function that takes
    the access and the handler separately, so the two cannot disagree. *)

include Http_server_eio.Router.Typed with type state = Mcp_server.server_state
