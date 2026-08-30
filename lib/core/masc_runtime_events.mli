(** Runtime_events event registrations for masc (Wave 2A).

    Consumed by Olly or custom [Runtime_events.Callbacks] programs.
    [ev_turn] is a span event: consumers receive [Begin]/[End] bounds
    via a single [Runtime_events.Type.span] handler. *)

type Runtime_events.User.tag +=
  | Turn

val emit_turn_start : unit -> unit
(** Record the opening bound ([Begin]) of a turn span in the
    Runtime_events ring buffer.  Safe to call from any fiber; the
    underlying write is a single domain-local buffer append. *)

val emit_turn_end : unit -> unit
(** Record the closing bound ([End]) of a turn span.  Pair with
    [emit_turn_start] around the turn body (the consumer pairs them
    by domain+timestamp). *)

val with_turn_span : (unit -> 'a) -> 'a
(** [with_turn_span f] emits the [Begin] bound, runs [f], and emits the
    [End] bound even if [f] raises.  Uses {!Eio_guard.protect} so the
    closing bound runs under [Eio.Switch] when the runtime is active and
    a body exception is preserved.  Brackets the pair so a caller cannot
    emit a start without its matching end. *)

val prune_stale_dumps : dir:string -> unit
(** Remove [<pid>.events] ring-buffer dumps in [dir] whose owning process no
    longer exists.

    [Runtime_events.start] writes the buffer as [<pid>.events]. The OCaml
    runtime removes it after a normal process exit, but an ungraceful exit can
    leave the dump behind. This pass removes those crash remnants before they
    accumulate. A dump belonging to a live process is left alone: a consumer
    (Olly, an in-process cursor) may be reading it. Existence is probed with
    signal 0; [EPERM] and any other error count as live, since deleting a
    buffer under an active reader is worse than leaving a file.

    Only stems that are plain decimal digits are treated as pids, so files like
    [0x10.events] or [olly.events] are left alone. Setting
    [OCAML_RUNTIME_EVENTS_PRESERVE] disables pruning entirely: the runtime keeps
    buffers on purpose in that mode, and every preserved file has a dead pid.

    Known limitation: liveness is a same-namespace test. If the directory is
    shared with a host or sibling container, a pid outside this namespace probes
    as [ESRCH] and its buffer looks stale even while its process runs. Set
    [OCAML_RUNTIME_EVENTS_PRESERVE] in that topology.

    Failures are logged, never raised — pruning must not prevent the listener
    from starting. Exposed for tests; {!start_listener} passes the directory
    reported by [Runtime_events.path]. *)

val start_listener : unit -> unit
(** Install the Runtime_events ring buffer listener.

    Prunes stale dumps via {!prune_stale_dumps} right after starting — the
    directory comes from [Runtime_events.path], so [OCAML_RUNTIME_EVENTS_DIR] is
    honoured — which keeps the directory from accumulating one buffer per run.

    Idempotent-safe per [Runtime_events] semantics. Should be called
    once, early inside the [Eio_main.run] entry. Set
    [MASC_RUNTIME_EVENTS=0] to skip the listener on hosts where the OCaml
    runtime event ring cannot be opened. *)
