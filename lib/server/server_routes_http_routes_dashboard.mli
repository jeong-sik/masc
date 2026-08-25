(** Server_routes_http_routes_dashboard — HTTP routes for the
    operator dashboard surface.

    Top-level router builder for [/api/v1/broadcast],
    [/api/v1/dashboard/*], and the broader operator-facing JSON
    surface. *)

val exact_lane_run_page_max : int
(** Largest page [GET /api/v1/dashboard/exact-lane-runs] will serve. Exposed
    because the store behind that route bounds its retained history, and a
    bound below this would let the monitor's cursor page off the end of the
    store; a test pins the relation. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val exact_lane_run_permission : Masc_domain.permission
  val runtime_probe_read_permission : Masc_domain.permission

  val fusion_run_detail_response :
    registry:Fusion_run_registry.t ->
    path:string ->
    [ `Bad_request | `Not_found | `OK ] * Yojson.Safe.t

  val fusion_run_list_response :
    registry:Fusion_run_registry.t -> Yojson.Safe.t

  type gate_mode_recovery =
    | Recovery_completed of Keeper_gate.operator_recovery_report
    | Recovery_failed of string
    | Recovery_not_requested

  val gate_mode_change_json :
    Keeper_gate_mode.change -> gate_mode_recovery -> Yojson.Safe.t
end
