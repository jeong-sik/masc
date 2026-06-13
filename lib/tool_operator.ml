type 'a context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  mcp_session_id : string option;
}

type tool_result = Tool_result.result

let operator_dispatcher = ref (fun _ctx ~name:_ ~args:_ -> None)
let schemas_val = ref []
let remote_schemas_val = ref []
let remote_tool_names_val = ref []

let schemas () = !schemas_val
let remote_schemas () = !remote_schemas_val
let remote_tool_names () = !remote_tool_names_val

let register_operator_tools ~dispatch ~schemas ~remote_schemas =
  operator_dispatcher := dispatch;
  schemas_val := schemas;
  remote_schemas_val := remote_schemas;
  remote_tool_names_val := List.map (fun (s : Masc_domain.tool_schema) -> s.name) remote_schemas
;;

let dispatch ctx ~name ~args =
  !operator_dispatcher ctx ~name ~args
;;
