(** Runtime_events event registrations for masc (Wave 2A).

    Consumed by Olly or custom [Runtime_events.Callbacks] programs.
    [ev_turn] is a span event: consumers receive [Begin]/[End] bounds
    via a single [Runtime_events.Type.span] handler. *)

type Runtime_events.User.tag +=
  | Turn

val ev_turn : Runtime_events.Type.span Runtime_events.User.t
(** Span event bracketing an agent turn.  Consumers register with
    [Runtime_events.Callbacks.add_user_event Runtime_events.Type.span]
    to receive both bounds keyed by timestamp; no external
    correlation id is needed. *)

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

val start_listener : unit -> unit
(** Install the Runtime_events ring buffer listener.

    Idempotent-safe per [Runtime_events] semantics. Should be called
    once, early inside the [Eio_main.run] entry. Set
    [MASC_RUNTIME_EVENTS=0] to skip the listener on hosts where the OCaml
    runtime event ring cannot be opened. *)
