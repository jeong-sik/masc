type owner_keeper_identity = string * string option

type t = {
  agent_name : string;
  token : string option;
  has_explicit_agent_name : bool;
  verified_internal_keeper_runtime : bool;
  internal_keeper_runtime_tool : bool;
  owner_keeper_identity : owner_keeper_identity option;
  mode_gate_error : string option;
}

val should_read_legacy_persisted_agent_name :
  has_explicit_agent_name:bool -> agent_name:string -> bool

val caller_agent_name_from_arguments : Yojson.Safe.t -> string option

val resolve :
  config:Coord_utils_backend_setup.config ->
  tool_name:string ->
  arguments:Yojson.Safe.t ->
  identity:Agent_identity.t ->
  cached_resolved_agent:string option ->
  mcp_session_id:string option ->
  auth_token:string option ->
  internal_keeper_runtime:bool ->
  room_initialized:(unit -> bool) ->
  read_mcp_session_agent:(unit -> string option) ->
  read_term_session_agent:(unit -> string option) ->
  log_mcp_exn:(label:string -> exn -> unit) ->
  t
