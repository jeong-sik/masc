(** Where the operator's browser comes back to after consenting.

    One unauthenticated route, by necessity: the request arrives from the
    provider's redirect and carries no token this server issued. What stands
    in for one is the state it echoes -- unguessable, minted by this process,
    redeemable once, and gone when the window closes. A request that does not
    carry a live one gets nothing.

    Starting a login is authenticated and lives with the other Keeper POSTs
    ([POST /api/v1/keepers/<keeper>/oauth-login]); only the half the browser
    reaches is here.

    Beside it, two reads that look like the rest of the operator snapshot:
    [GET /api/v1/keepers/oauth/providers] lists what a Keeper can be attached
    to -- file names and labels that ship with the binary -- and
    [GET /api/v1/keepers/oauth/attached-tools?keeper=<name>] lists what each
    of them currently offers that Keeper. Tool names only: a screen has no
    use for a credential and every use for knowing whether one is there. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t
