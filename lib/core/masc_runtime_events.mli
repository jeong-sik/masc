(** Runtime_events event registrations for masc-mcp (Wave 2A pilot).

    Consumed by Olly or custom [Runtime_events.Callbacks] programs.
    Emit sites for [ev_turn_start]/[ev_turn_end] will be added in
    follow-up PRs; this module currently only installs the listener
    and reserves event handles. *)

type Runtime_events.User.tag +=
  | Turn_start
  | Turn_end

val ev_turn_start : unit Runtime_events.User.t
(** Reserved: emit at the beginning of an agent turn. *)

val ev_turn_end : unit Runtime_events.User.t
(** Reserved: emit at the end of an agent turn. *)

val start_listener : unit -> unit
(** Install the Runtime_events ring buffer listener.

    Idempotent-safe per [Runtime_events] semantics. Should be called
    once, early inside the [Eio_main.run] entry. *)
