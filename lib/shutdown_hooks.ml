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

(** Call all registered shutdown hooks with per-hook timing. *)
let run_all () =
  let t0 = Unix.gettimeofday () in
  (* Cancel orchestrator first *)
  (match !cancel_orchestrator_ref with
   | Some cancel ->
     let t_start = Unix.gettimeofday () in
     Log.Server.info "Cancelling orchestrator...";
     cancel ();
     Log.Server.info "[Shutdown] orchestrator cancelled (%.2fs)"
       (Unix.gettimeofday () -. t_start)
   | None ->
     Log.Server.info "[Shutdown] no orchestrator registered, skipping");
  (* Close all SSE clients *)
  let t_sse = Unix.gettimeofday () in
  let sse_count = Sse.close_all_clients () in
  Log.Server.info "Closed %d SSE clients (%.2fs)"
    sse_count (Unix.gettimeofday () -. t_sse);
  (* Close WebSocket sessions *)
  let t_ws = Unix.gettimeofday () in
  let ws_count = Server_mcp_transport_ws.close_all () in
  Log.Server.info "Closed %d WebSocket sessions (%.2fs)"
    ws_count (Unix.gettimeofday () -. t_ws);
  Log.Server.info "[Shutdown] hooks total: %.2fs"
    (Unix.gettimeofday () -. t0)
