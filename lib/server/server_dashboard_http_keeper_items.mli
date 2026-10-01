(** Read-only Item account projection for an authenticated TUI or dashboard.
    The selected Keeper comes from the URL; this route never buys or equips. *)

val route : string -> string option
(** Exact [/api/v1/keepers/<name>/items] path. *)

val permission : Masc_domain.permission

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit
