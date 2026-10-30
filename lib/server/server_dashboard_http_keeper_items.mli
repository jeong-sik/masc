(** Read-only Item account projection for an authenticated TUI or dashboard.
    The selected Keeper comes from the URL; this route never buys or equips.
    Ready account, catalog and [account_revision] come from one current Candle
    view. Off carries a null revision; Disabled carries the same reason and
    revision as the roster observation. Ledger/time failures remain 503. *)

val route : string -> string option
(** Exact [/api/v1/keepers/<name>/items] path. *)

val permission : Masc_domain.permission

val handle_get :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> string -> unit

(** [expected_workspace] is an optional query binding to the canonical base path
    emitted by health. A bound mismatch is 409 before Keeper/account reads;
    a blank binding is 400. Unbound callers request the current workspace. *)
