(** Thin compatibility wrapper over the HTTP SSE connection registry.

    Cleanup loops historically read this module while request handlers mutated
    [Server_mcp_transport_http_conn]. Re-export the conn implementation so both
    paths observe the same registry and guard tables. *)

type deps = Server_mcp_transport_http_types.deps

include Server_mcp_transport_http_conn

let respond_sse_rate_limited =
  Server_mcp_transport_http_respond.respond_sse_rate_limited
;;

let () = Shutdown_hooks.register_sse_cleanup (fun () ->
  let closed = Sse.close_all_clients () in
  closed, active_session_count ()
)

