(** Select scope-matching immutable components when available. Cold and
    foreign-scope reads retain the existing authoritative HTTP reader.
    Namespace truth has one owner: its execution/Shell cache composition. *)

val select_shell_json :
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?request:Httpun.Request.t ->
  ?timing:Server_timing.t ->
  ?light:bool ->
  Workspace.config ->
  Yojson.Safe.t

type tools_response =
  | Tools_json of Yojson.Safe.t
  | Tools_prepared of Dashboard_snapshot.tools_projection

val select_tools_response :
  ?keeper:string -> ?timing:Server_timing.t -> Workspace.config -> tools_response

val select_tools_json :
  ?keeper:string ->
  ?timing:Server_timing.t ->
  Workspace.config ->
  Yojson.Safe.t

module For_testing : sig
  val select_tools_response :
    fallback:(keeper:string option -> timing:Server_timing.t -> Workspace.config -> Yojson.Safe.t) ->
    ?keeper:string -> ?timing:Server_timing.t -> Workspace.config -> tools_response
end

val select_telemetry_summary_json :
  ?timing:Server_timing.t ->
  Workspace.config ->
  Yojson.Safe.t

val select_project_snapshot_json :
  state:Mcp_server.server_state ->
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?timing:Server_timing.t ->
  Httpun.Request.t ->
  Yojson.Safe.t
