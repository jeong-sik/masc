(* The Esc decision while the chat view shows a keeper whose turn is live,
   extracted from the dispatch arm in masc_tui.ml so a test can pin the
   table. test_tui_esc_interrupt pins it; if the dispatch's contract moves,
   move this derivation and the test together.

   The swallow exists for one case: an accidental double-Esc right after the
   first interrupt request, which must not leave the view. That guard is a
   grace window, not a state: a turn parked in an uncancellable section
   keeps streaming after its signal (masc #29229), possibly indefinitely,
   and a swallow keyed on the signal's existence held Esc for the rest of
   the session. Past the window Esc leaves the view; leaving cancels
   nothing — the interrupt proceeds server-side and the pane can be
   reopened. A declined or errored request has nothing pending, so it is
   not guarded at all.

   Both clocks here are monotonic ([Mtime_clock.elapsed_ns]): a wall-clock
   step backwards would make a stale signal look fresh and re-arm the guard
   indefinitely -- the trap this module exists to close. *)

type action =
  | Launch_interrupt
  | Swallow
  | Leave

(* 2 s, in the nanoseconds [Mtime_clock.elapsed_ns] answers in. *)
let grace_window_ns = 2_000_000_000L

let action ~now_ns (interrupt : Masc_tui_keeper_chat_transcript.interrupt) =
  match interrupt with
  | Not_requested -> Launch_interrupt
  | Signal_sent { signalled_at_ns; _ } ->
    if Int64.sub now_ns signalled_at_ns <= grace_window_ns then Swallow else Leave
  | Signal_declined _ | Signal_error _ -> Leave
;;
