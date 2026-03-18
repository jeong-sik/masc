(** Tool_lodge -- DEPRECATED (#1596).
    Lodge heartbeat removed; Keeper is the sole autonomous runtime.
    This stub preserves the module interface until Phase 3 cleanup. *)

let init () = ()
let load_agents_config () = ()
let get_all_agents () = []
let autonomous_loop ~net:_ _args = (false, "Lodge heartbeat deprecated (#1596)")

let tools : Types.tool_schema list = []

let handle_tool ~net:_ _name _args =
  (false, "Lodge heartbeat deprecated (#1596)")
