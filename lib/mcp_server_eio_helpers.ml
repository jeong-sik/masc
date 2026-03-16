(** Mcp_server_eio_helpers — Small utility functions extracted from mcp_server_eio.ml

    Provides functions needed by both mcp_server_eio.ml and tool_inline_dispatch.ml
    without circular dependencies.
*)

(** Unregister agent synchronously - adapter for Session.registry.
    Directly removes from hashtable without extra mutex layer.
    Safe in Eio single-fiber context. *)
let unregister_sync (registry : Session.registry) ~agent_name =
  Hashtbl.remove registry.Session.sessions agent_name;
  Log.Session.info "Session unregistered (sync): %s (total: %d)"
    agent_name (Hashtbl.length registry.sessions)
