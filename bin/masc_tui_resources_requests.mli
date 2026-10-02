(** MCP resource requests. [launch] is the caller's workspace request boundary:
    it checks endpoint identity, owns cancellation and stamps completion. [check]
    rechecks the same captured authority after obtaining an MCP session. *)

val launch_list
  :  Masc_tui_types.state
  -> host:string
  -> launch:
       (deliver:
          ((Masc_tui_mcp.resource list, string) result
           -> Masc_tui_async_protocol.async_msg)
        -> (unit -> (Masc_tui_mcp.resource list, string) result)
        -> unit)
  -> check:(unit -> (unit, string) result)
  -> unit

(** Mark the pending URI before launching. Changing resources clears the old
    content, error and scroll; re-reading the same resource keeps its content.
    Resource_read failure attribution is applied exactly once. *)
val launch_read
  :  Masc_tui_types.state
  -> host:string
  -> launch:
       (deliver:
          ((Masc_tui_mcp.resource_content list, string) result
           -> Masc_tui_async_protocol.async_msg)
        -> (unit -> (Masc_tui_mcp.resource_content list, string) result)
        -> unit)
  -> check:(unit -> (unit, string) result)
  -> uri:string
  -> unit
