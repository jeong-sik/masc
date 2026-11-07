(** Server_routes_http_routes_runtime_config — HTTP routes that edit runtime.toml from the
    dashboard. *)

val add_routes : Http_server_eio.Router.t -> Http_server_eio.Router.t

module For_testing : sig
  val parse_runtime_route_body :
    string ->
    (string * string * string list, string) result
  (** For_testing projection of the routing body parser: the lane string,
      what the body asked for ("runtime_id" or "runtime_ids" for a set,
      "create" or "remove" for a lane action), and the runtime ids it
      carried. Exposes the wire contract without exporting the private body
      variant. *)

  val handle_runtime_assignment_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Httpun.Reqd.t ->
    string ->
    unit

  val handle_runtime_routing_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Httpun.Reqd.t ->
    string ->
    unit
  (** The routing POST after authentication: parse the body, call the
      Runtime writer it names, answer with the receipt or the refusal. *)

  val handle_runtime_config_raw_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Httpun.Reqd.t ->
    string ->
    unit
  (** The raw-source POST after authentication, including its revision guard. *)

  val handle_tui_preference_post :
    Mcp_server.server_state ->
    string ->
    Httpun.Request.t ->
    Httpun.Reqd.t ->
    string ->
    unit
  (** The [tui] table POST after authentication: one parsed change, written
      through Runtime's config commit (RFC-0482 §3.1). *)

  val handle_tui_preferences_get :
    Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
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
    Httpun.Reqd.t ->
    string ->
    unit
end
