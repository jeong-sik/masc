(** Boundary for calling keeper tools from non-keeper entrypoints. *)

type 'a context = {
  config : Coord.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
}

let create ~config ~agent_name ~sw ~clock ~proc_mgr ~net =
  { config; agent_name; sw; clock; proc_mgr; net }

let to_tool_keeper_context (ctx : _ context) : _ Tool_keeper.context =
  {
    Tool_keeper.config = ctx.config;
    agent_name = ctx.agent_name;
    sw = ctx.sw;
    clock = ctx.clock;
    proc_mgr = ctx.proc_mgr;
    net = ctx.net;
  }

let dispatch ctx ~name ~args =
  Tool_keeper.dispatch (to_tool_keeper_context ctx) ~name ~args

let dispatch_stream ~on_text_delta ctx ~name ~args =
  Tool_keeper.dispatch_stream ~on_text_delta (to_tool_keeper_context ctx) ~name
    ~args
