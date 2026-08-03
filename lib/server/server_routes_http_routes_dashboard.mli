(** Server_routes_http_routes_dashboard — HTTP routes for the
    operator dashboard surface.

    Top-level router builder for [/api/v1/broadcast],
    [/api/v1/dashboard/*], and the broader operator-facing JSON
    surface. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

val dashboard_dev_token_path : string -> string
(** [<base_path>/.masc/auth/dashboard.token] — the canonical
    dashboard dev-token file written on boot. *)

type dashboard_dev_token =
  Server_routes_http_dashboard_dev_token.dashboard_dev_token
type dashboard_dev_token_error =
  Server_routes_http_dashboard_dev_token.token_error

val ensure_dashboard_dev_token :
  string -> (dashboard_dev_token, dashboard_dev_token_error) result
(** Idempotent boot helper: returns the canonical worker-scoped dashboard
    dev-token identity, generating + persisting one to
    {!dashboard_dev_token_path} on first call. Persistence and rotation
    failures remain typed. *)

module For_testing : sig
  type gate_mode_recovery =
    | Recovery_completed of Keeper_gate.operator_recovery_report
    | Recovery_failed of string
    | Recovery_not_requested

  val gate_mode_change_json :
    Keeper_gate_mode.change -> gate_mode_recovery -> Yojson.Safe.t
end
