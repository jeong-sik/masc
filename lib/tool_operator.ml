type 'a context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  delegated_dispatch :
    (name:string -> args:Yojson.Safe.t -> Tool_result.result option) option;
  mcp_session_id : string option;
}

type tool_result = Tool_result.result

type 'a registry = {
  dispatch : 'a context -> name:string -> args:Yojson.Safe.t -> tool_result option;
  schemas : Masc_domain.tool_schema list;
  remote_schemas : Masc_domain.tool_schema list;
  remote_tool_names : string list;
}

let registry : 'a registry Atomic.t =
  Atomic.make {
    dispatch = (fun _ctx ~name:_ ~args:_ -> None);
    schemas = [];
    remote_schemas = [];
    remote_tool_names = [];
  }

let register_operator_tools ~dispatch ~schemas ~remote_schemas =
  Atomic.set registry {
    dispatch;
    schemas;
    remote_schemas;
    remote_tool_names = List.map (fun (s : Masc_domain.tool_schema) -> s.name) remote_schemas;
  }
;;

let dispatch ctx ~name ~args =
  (Atomic.get registry).dispatch ctx ~name ~args
;;

let schemas () = (Atomic.get registry).schemas
let remote_schemas () = (Atomic.get registry).remote_schemas
let remote_tool_names () = (Atomic.get registry).remote_tool_names
