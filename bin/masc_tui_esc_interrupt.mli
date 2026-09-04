(** What Esc does while the chat view shows a keeper whose turn is live.

    The dispatch arm in [masc_tui.ml] reads this table instead of carrying
    the logic inline. [grace_window_sec] is the deliberate protection the
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

val grace_window_sec : float
(** How long after the signal a second Esc is still read as the accidental
    double press. *)

val action : now:float -> Masc_tui_keeper_chat_transcript.interrupt -> action
(** [now] and the state's [signalled_at] are Unix epoch seconds. A timestamp
    ahead of [now] reads as a fresh signal: negative age stays inside the
    guard. *)
