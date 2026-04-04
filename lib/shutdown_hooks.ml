(** Shutdown Hooks - Centralized graceful shutdown management

    Provides a registry for cleanup functions that should be called
    during graceful shutdown.

    @since 0.5.0
*)

(** Registered cancel function for orchestrator *)
let cancel_orchestrator_ref : (unit -> unit) option ref = ref None

(** Register the orchestrator cancel function *)
let register_cancel_orchestrator (f : unit -> unit) =
  cancel_orchestrator_ref := Some f

(** Call all registered shutdown hooks *)
let run_all () =
  (* Cancel orchestrator first *)
  (match !cancel_orchestrator_ref with
   | Some cancel ->
     Log.Server.info "Cancelling orchestrator...";
     cancel ()
   | None -> ());
  (* Close all SSE clients *)
  let sse_count = Sse.close_all_clients () in
  Log.Server.info "Closed %d SSE clients" sse_count;
  (* Close WebSocket sessions *)
  let ws_count = Server_mcp_transport_ws.close_all () in
  Log.Server.info "Closed %d WebSocket sessions" ws_count
