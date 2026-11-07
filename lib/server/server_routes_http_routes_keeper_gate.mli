(** Server_routes_http_routes_keeper_gate — HTTP routes for the Keeper Gate dashboard surface. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  type gate_mode_recovery =
    | Recovery_completed of Keeper_gate.operator_recovery_report
    | Recovery_failed of string
    | Recovery_not_requested

  val gate_mode_change_json :
    Keeper_gate_mode.change -> gate_mode_recovery -> Yojson.Safe.t
end
