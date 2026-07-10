type tool_profile =
  | Full
  | Managed_agent
  | Operator_remote

type runtime = {
  base_path : string;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  handle_request :
    ?profile:tool_profile ->
    ?mcp_session_id:string ->
    ?otel_mcp_protocol_version:string ->
    ?otel_transport_context:Otel_dispatch_hook.transport_context ->
    ?auth_token:string ->
    ?internal_keeper_runtime:bool ->
    string ->
    Yojson.Safe.t;
  clear_resource_subscriptions_for_session : string -> unit;
}

type deps = {
  get_origin : Httpun.Request.t -> string;
  cors_headers : string -> (string * string) list;
  auth_token_from_request : Httpun.Request.t -> string option;
  is_ready : unit -> bool;
  get_runtime_result : unit -> (runtime, string) result;
  get_base_path : unit -> string;
}
