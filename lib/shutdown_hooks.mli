(** Shutdown_hooks — centralised graceful shutdown sequencer.

    Wired into the SIGINT / SIGTERM signal handlers in
    [bin/main_eio] and [bin/main_stdio_eio]; cancels the
    orchestrator first, then drains SSE / WebSocket sessions,
    flushes metric / stress buffers,and clears
    session-identity state. Each step is timed via
    [Unix.gettimeofday] and logged through [Log.Server.info] so
    operators can attribute slow shutdowns to a specific stage.

    Internal state (the [cancel_orchestrator_ref] WORM
    [Atomic.t (unit -> unit) option]) is hidden — callers consume
    only the registration entry point and the runner.

    @since 0.5.0 *)

val register_cancel_orchestrator : (unit -> unit) -> unit
(** Stash the orchestrator-cancel function for {!run_all} to
    invoke first during shutdown. The slot is a single-writer
    [Atomic.t]; calling [register_cancel_orchestrator] more than
    once silently overwrites the previous value (last-writer
    wins), matching the existing single-bootstrap pattern. *)

val run_all : unit -> unit
(** Run the shutdown sequence in order:

    1. Cancel the registered orchestrator (if any).
    2. Close every SSE client via [Sse.close_all_clients].
    3. Close every WebSocket session via
       [Server_mcp_transport_ws.close_all].
    4. Flush [Heuristic_metrics] and [Agent_stress] buffers
       (Eio.Cancel.Cancelled re-raised; any other exception is
       logged at warn and swallowed so a partial flush failure
       cannot block shutdown of the rest of the chain).
    5. Clear [Agent_registry_eio] session caches.
    6. Best-effort purge of transient files under [<MASC_BASE_PATH>/.masc/tmp/].
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
