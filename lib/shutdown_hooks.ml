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
     Printf.eprintf "[Shutdown] Cancelling orchestrator...\n%!";
     cancel ()
   | None -> ());
  (* Close all SSE clients *)
  let sse_count = Sse.close_all_clients () in
  Printf.eprintf "[Shutdown] Closed %d SSE clients\n%!" sse_count
