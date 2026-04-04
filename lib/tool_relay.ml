(** Relay tools - Infinite context via handoff (all tools orphaned) *)

type context = {
  config: Room.config;
  agent_name: string;
  sw: Eio.Switch.t;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
}

let schemas : Types.tool_schema list = []

let dispatch (_ctx : context) ~name:_ ~args:_ : (bool * string) option = None
