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
   not guarded at all. *)

type action =
  | Launch_interrupt
  | Swallow
  | Leave

let grace_window_sec = 2.0

let action ~now (interrupt : Masc_tui_keeper_chat_transcript.interrupt) =
  match interrupt with
  | Not_requested -> Launch_interrupt
  | Signal_sent { signalled_at; _ } ->
    (* A timestamp ahead of [now] is a signal that has demonstrably just
       been sent: negative age stays inside the guard. *)
    if now -. signalled_at <= grace_window_sec then Swallow else Leave
  | Signal_declined _ | Signal_error _ -> Leave
;;
