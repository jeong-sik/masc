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

val execute_output_heartbeat_s : float
(** Seconds of silence after which [GET /api/v1/dashboard/execute-output/<keeper>]
    writes a keepalive comment. Exposed so the terminal's idle timeout is
    counted in these intervals rather than in a number of its own. *)

val add_routes :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val parse_runtime_route_body :
    string ->
    (string * string * string list, string) result
  (** For_testing projection of the routing body parser: the lane string,
      what the body asked for ("runtime_id" or "runtime_ids" for a set,
      "create" or "remove" for a lane action), and the runtime ids it
      carried. Exposes the wire contract without exporting the private body
      variant. *)
  val exact_lane_run_permission : Masc_domain.permission
  val runtime_probe_read_permission : Masc_domain.permission

  val handle_runtime_assignment_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Http_reqd.t ->
    string ->
    unit

  val handle_runtime_routing_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Http_reqd.t ->
    string ->
    unit
  (** The routing POST after authentication: parse the body, call the
      Runtime writer it names, answer with the receipt or the refusal. *)

  val handle_runtime_config_raw_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Http_reqd.t ->
    string ->
    unit
  (** The raw-source POST after authentication, including its revision guard. *)

  val handle_tui_preference_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Http_reqd.t ->
    string ->
    unit
  (** The [tui] table POST after authentication: one parsed change, written
      through Runtime's config commit (RFC-0482 §3.1). *)

  val handle_tui_preferences_get :
    Mcp_server.server_state -> Httpun.Request.t -> Http_reqd.t -> unit
  (** The [tui] table GET after authentication: the settings only. *)

  val handle_runtime_assignment_post_with :
    set_assignment:
      (runtime_config_path:string ->
       keeper_name:string ->
       runtime_id:string option ->
       expected:Runtime.keeper_assignment_revision ->
       unit ->
       (Runtime.keeper_assignment_write Runtime.config_lock_receipt,
        Runtime.keeper_assignment_cas_error) result) ->
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Http_reqd.t ->
    string ->
    unit

  val fusion_run_detail_response :
    reader:Masc_board_handlers.Board_access.reader ->
    registry:Fusion_run_registry.t ->
    path:string ->
    [ `Bad_request | `Not_found | `OK ] * Yojson.Safe.t

  val fusion_run_list_response :
    reader:Masc_board_handlers.Board_access.reader ->
    registry:Fusion_run_registry.t -> Yojson.Safe.t
end
