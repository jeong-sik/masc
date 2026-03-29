type deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  get_server_state_opt : unit -> Mcp_server.server_state option;
  get_base_path : unit -> string;
  get_sw : unit -> Eio.Switch.t option;
  get_clock : unit -> float Eio.Time.clock_ty Eio.Resource.t option;
  verify_mcp_auth : base_path:string -> Httpun.Request.t -> (unit, string) result;
  verify_operator_mcp_auth :
    base_path:string -> Httpun.Request.t -> (unit, string) result;
}
