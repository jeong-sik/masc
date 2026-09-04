(** What Esc does while the chat view shows a keeper whose turn is live.

    The dispatch arm in [masc_tui.ml] and the footer's escape hint in
    [masc_tui_render.ml] both read this table, so the hint and the act can
    never diverge. [grace_window_ns] is the deliberate protection the
    swallow was written for: a second Esc right after the first interrupt
    request is an accidental double press, not a request to leave. Past the
    window, a turn that keeps streaming after its signal (masc #29229: a
    turn parked in an uncancellable section may stream indefinitely) no
    longer holds Esc — leaving cancels nothing, the interrupt proceeds
    server-side, and the pane can be reopened. A declined or errored
    interrupt has nothing pending at all, so Esc leaves immediately. *)

type action =
  | Launch_interrupt  (** no interrupt requested yet; Esc is the first press *)
  | Swallow  (** inside the grace window; the press is spent, the view stays *)
  | Leave  (** the interrupt is stale, declined, or errored; Esc leaves the
               view without cancelling anything *)

val grace_window_ns : int64
(** How long after the signal a second Esc is still read as the accidental
    double press: 2 s, in nanoseconds. *)

val action :
  now_ns:int64 -> Masc_tui_keeper_chat_transcript.interrupt -> action
(** [now_ns] and the state's [signalled_at_ns] are monotonic nanoseconds
    from [Mtime_clock.elapsed_ns] — never wall-clock values, so a backward
    clock step cannot re-arm the guard. *)
