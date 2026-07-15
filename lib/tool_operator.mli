type 'a context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  publication_recovery_provider :
    Keeper_publication_recovery_availability.provider;
  mcp_session_id : string option;
}

type tool_result = Tool_result.result

val dispatch :
  float Eio.Time.clock_ty context ->
  name:string ->
  args:Yojson.Safe.t ->
  Tool_result.result option

val schemas : unit -> Masc_domain.tool_schema list
val remote_schemas : unit -> Masc_domain.tool_schema list
val remote_tool_names : unit -> string list

val register_operator_tools :
  dispatch:(float Eio.Time.clock_ty context -> name:string -> args:Yojson.Safe.t -> Tool_result.result option) ->
  schemas:Masc_domain.tool_schema list ->
  remote_schemas:Masc_domain.tool_schema list ->
  unit
