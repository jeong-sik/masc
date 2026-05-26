(** RFC-0182 §3.1 — coord dispatch dependency inversion ref.

    [Agent_tool_in_process_runtime] is compiled very early in module
    order (transitively imported by [Keeper_exec_tools]). [Tool_coord]
    is compiled late (it depends on [Keeper_runtime] which depends on
    most of the keeper layer). A direct import from
    [Agent_tool_in_process_runtime] to [Tool_coord] would close a
    cycle.

    Resolution: register [Tool_coord.dispatch] into this ref from a
    late-compiled bootstrap module ([Mcp_server_eio_execute]).
    [Agent_tool_in_process_runtime.handle_masc_coord] reads the ref.
    Until registered the ref is a no-op returning [None] (the same
    behavior the descriptor projection stub had).

    The ref is process-global mutable — acceptable because masc-mcp is
    a single-process server with a single coord dispatcher. *)

let dispatch
  : (config:Coord.config
     -> agent_name:string
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.t option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~name:_ ~args:_ -> None)
;;
