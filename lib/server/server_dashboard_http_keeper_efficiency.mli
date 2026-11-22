(** Fleet Keeper efficiency month view. See the implementation for the
    route contract. *)

val route_path : string
(** ["/api/v1/keeper-efficiency"]. *)

val month_parameter : Httpun.Request.t -> string
(** The requested month: a trimmed non-empty [month] query value, else the
    wall clock's current [YYYY-MM]. Exposed so the query contract is tested
    without a server state. *)

val active_only_parameter : Httpun.Request.t -> (bool, string) result
(** Strict parser for the optional [active_only] query parameter: absent or
    blank defaults to [false]; ["true"]/["1"] yields [true]; ["false"]/["0"]
    yields [false]; any other value is an [Error]. *)

val handle_get : Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
(** Answer [GET !route_path]. [month] defaults to the wall clock's current
    month; an invalid month answers [400 keeper_efficiency_invalid_month];
    an invalid [active_only] answers [400 keeper_efficiency_invalid_active_only];
    a storage failure answers [503 keeper_efficiency_unavailable]. *)
