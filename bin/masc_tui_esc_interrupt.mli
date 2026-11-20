(** What Ctrl-C does while the chat view shows a keeper whose turn is live.
    Esc only leaves the chat (RFC §3.4).

    [Queue_steer.interrupt_active_chat_turn] and the chat footer's Ctrl-C
    hint both read this table, so the hint and the act can never diverge.
    [grace_window_ns] is the deliberate protection the swallow was written
    for: a second Ctrl-C right after the first interrupt request is an
    accidental double press, not a request to quit. Past the window, a turn
    that keeps streaming after its signal (masc #29229: a turn parked in an
    uncancellable section may stream indefinitely) no longer holds Ctrl-C:
    the press goes on to arm quit and the interrupt proceeds server-side. A
    declined or errored interrupt has nothing pending at all, so the press
    goes on at once. *)

type action =
  | Launch_interrupt  (** no interrupt requested yet; this press sends it *)
  | Swallow  (** inside the grace window; the press is spent on the turn *)
  | Leave  (** the interrupt is stale, declined, or errored; the press goes
               on to arm quit without sending another *)

val grace_window_ns : int64
(** How long after the signal a second Ctrl-C is still read as the accidental
    double press: 2 s, in nanoseconds. *)

val pending_action : now_ns:int64 -> requested_at_ns:int64 -> action
(** A pending HTTP acknowledgement protects the same accidental-double-press
    grace, then permits navigation without sending another interrupt. *)

val action :
  now_ns:int64 -> Masc_tui_keeper_chat_transcript.interrupt -> action
(** [now_ns] and the state's [signalled_at_ns] are monotonic nanoseconds
    from [Mtime_clock.elapsed_ns] — never wall-clock values, so a backward
    clock step cannot re-arm the guard. *)

val observed_action : now_ns:int64 -> current_token:string option ->
  previous:(string * int64 * bool) option -> action option
(** Previous token, request time, and whether it failed. Recent duplicate
    input is swallowed even after token disappearance or successor publication. *)
