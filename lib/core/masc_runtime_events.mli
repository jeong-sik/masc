(** Runtime_events event registrations for masc-mcp (Wave 2A pilot).

    Consumed by Olly or custom [Runtime_events.Callbacks] programs.
    Emit sites for [ev_turn_start]/[ev_turn_end] will be added in
    follow-up PRs; this module currently only installs the listener
    and reserves event handles. *)

type Runtime_events.User.tag +=
  | Turn_start
  | Turn_end

val ev_turn_start : unit Runtime_events.User.t
(** Event handle for the beginning of an agent turn.  Prefer
    [emit_turn_start] for emission; exposed here so that callers
    building custom [Runtime_events.Callbacks.add_user_event] handlers
    can register a consumer. *)

val ev_turn_end : unit Runtime_events.User.t
(** Event handle for the end of an agent turn.  See [ev_turn_start]. *)

val emit_turn_start : unit -> unit
(** Record a turn-start event in the Runtime_events ring buffer.
    Safe to call from any fiber; the underlying write is a single
    domain-local buffer append. *)

val emit_turn_end : unit -> unit
(** Record a turn-end event in the Runtime_events ring buffer.  Pair
    with [emit_turn_start] around the turn body (the observer pairs
    them by seq). *)

val start_listener : unit -> unit
(** Install the Runtime_events ring buffer listener.

    Idempotent-safe per [Runtime_events] semantics. Should be called
    once, early inside the [Eio_main.run] entry. *)
