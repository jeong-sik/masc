(** Server_routes_http_routes_dashboard — HTTP routes for the
    operator dashboard surface.

    Top-level router builder for [/api/v1/broadcast],
    [/api/v1/dashboard/*], and the broader operator-facing JSON
    surface. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  type gate_mode_recovery =
    | Recovery_completed of Keeper_gate.operator_recovery_report
    | Recovery_failed of string
    | Recovery_not_requested

  val gate_mode_change_json :
    Keeper_gate_mode.change -> gate_mode_recovery -> Yojson.Safe.t
end
