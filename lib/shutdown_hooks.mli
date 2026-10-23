(** Shutdown_hooks — centralised graceful shutdown sequencer.

    Wired into the SIGINT / SIGTERM signal handlers in
    [bin/main_eio] and [bin/main_stdio_eio]; stops Keeper owners and
    workspace observation first, then drains SSE / WebSocket sessions and
    clears session-identity state. Each step is timed via
    [Unix.gettimeofday] and logged through [Log.Server.info] so
    operators can attribute slow shutdowns to a specific stage.

    Internal state (the [keeper_shutdown_ref] WORM
    [Atomic.t (unit -> unit) option]) is hidden — callers consume
    only the registration entry point and the runner.

    @since 0.5.0 *)

val register_keeper_shutdown : (unit -> unit) -> unit
(** Stash the Keeper-owner and workspace-observation shutdown function for
    {!run_all} to invoke first during shutdown. The slot is a single-writer
    [Atomic.t]; calling [register_keeper_shutdown] more than
    once silently overwrites the previous value (last-writer
    wins), matching the existing single-bootstrap pattern. *)

val register_sse_cleanup : (unit -> int * int) -> unit
(** Register a cleanup callback for SSE clients. Returns (closed_count, remaining_count). *)

val register_ws_cleanup : (unit -> int * int) -> unit
(** Register a cleanup callback for WebSocket sessions. Returns (closed_count, remaining_count). *)

val run_all : unit -> unit
(** Run the shutdown sequence in order:

    1. Stop the registered Keeper owners and workspace observation (if any).
    2. Close every SSE client via [Sse.close_all_clients].
    3. Close every WebSocket session via
       [Server_mcp_transport_ws.close_all].
    4. Clear [Client_registry_eio] session caches.
    5. Best-effort purge of transient files under [<MASC_BASE_PATH>/.masc/tmp/].
       Bounded by an inspect-budget (500 files) and a wall-time
       budget (250ms) so the synchronous Eio shutdown phase cannot
       overrun the configured force timeout. Per-file errors are
       logged and ignored; durable JSONL state and lock files
       outside [tmp/] are never touched.

    Each step's elapsed time and (where applicable) the count of
    affected resources are logged. The function never raises
    except for [Eio.Cancel.Cancelled], which is re-raised with
    its original backtrace so the parent fiber observes the
    cancel cleanly. *)
