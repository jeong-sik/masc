(** RFC-0182 §3.1 — workspace dispatch dependency inversion ref.

    [Keeper_tool_in_process_runtime] is compiled very early in module
    order (transitively imported by [Keeper_tool_dispatch_runtime]). [Tool_workspace]
    is compiled late (it depends on [Keeper_runtime] which depends on
    most of the keeper layer). A direct import from
    [Keeper_tool_in_process_runtime] to [Tool_workspace] would close a
    cycle.

    Resolution: register [Tool_workspace.dispatch] into this ref from a
    late-compiled bootstrap module ([Mcp_server_eio_execute]).
    [Keeper_tool_in_process_runtime.handle_masc_workspace_with_outcome] reads
    the ref.
    Until registered the ref is a no-op returning [None] (the same
    behavior the descriptor projection stub had).

    The ref is process-global mutable — acceptable because masc is
    a single-process server with a single workspace dispatcher. *)

let dispatch
  : (config:Workspace.config
     -> agent_name:string
     -> name:string
     -> args:Yojson.Safe.t
     -> Tool_result.result option)
      ref
  =
  ref (fun ~config:_ ~agent_name:_ ~name ~args:_ ->
    failwith
      (Printf.sprintf
         "workspace_dispatch_ref: dispatch called for tool %S before boot registration — \
          ensure Mcp_server_eio_execute registers Tool_workspace.dispatch"
         name))
;;
