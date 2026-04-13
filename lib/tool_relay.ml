(** Tool_relay — retired hidden relay surface.

    The old relay tools were hidden, low-usage, and no longer part of the
    supported coordination/runtime contract. Keep the module as a stub so the
    build graph does not need to change, but do not register or dispatch any
    tool names from here. *)

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

type tool_result = bool * string

let dispatch _ctx ~name:_ ~args:_ : tool_result option = None

let schemas : Types.tool_schema list = []
