(* What Ctrl-C does while the chat view shows a keeper whose turn is live
   (RFC §3.4; Esc only leaves the chat). [Queue_steer.interrupt_active_chat_turn]
   and the chat footer's hint read this table. test_tui_esc_interrupt pins
   the table and test_tui_chat_escape_and_interrupt_keys pins the keys.

   The swallow exists for one case: an accidental double Ctrl-C right after
   the first interrupt request, which must not go on to arm quit. That guard
   is a grace window, not a state: a turn parked in an uncancellable section
   keeps streaming after its signal (masc #29229), possibly indefinitely,
   and a swallow keyed on the signal's existence would hold Ctrl-C for the
   rest of the session. Past the window the press goes on to arm quit; the
   interrupt proceeds server-side. A declined or errored request has nothing
   pending, so it is not guarded at all.

   Both clocks here are monotonic ([Mtime_clock.elapsed_ns]): a wall-clock
   step backwards would make a stale signal look fresh and re-arm the guard
   indefinitely -- the trap this module exists to close. *)

type action =
  | Launch_interrupt
  | Swallow
  | Leave

(* 2 s, in the nanoseconds [Mtime_clock.elapsed_ns] answers in. *)
let grace_window_ns = 2_000_000_000L

let pending_action ~now_ns ~requested_at_ns =
  if Int64.sub now_ns requested_at_ns <= grace_window_ns then Swallow else Leave
;;

let action ~now_ns (interrupt : Masc_tui_keeper_chat_transcript.interrupt) =
  match interrupt with
  | Not_requested -> Launch_interrupt
  | Signal_sent { signalled_at_ns; _ } ->
    if Int64.sub now_ns signalled_at_ns <= grace_window_ns then Swallow else Leave
  | Admission_paused | Signal_declined _ | Signal_error _ | Signal_kept_back _ -> Leave
;;

(* A duplicate key belongs to the action just sent, even if its switch token
   disappeared or the next turn was published while the response travelled. *)
let observed_action ~now_ns ~current_token ~previous =
  match previous with
  | Some (token, _, true) when current_token = None || current_token = Some token -> Some Leave
  | Some (_, _, true) -> Option.map (fun _ -> Launch_interrupt) current_token
  | Some (_, sent_ns, false) when Int64.sub now_ns sent_ns <= grace_window_ns -> Some Swallow
  | Some (token, _, false) when current_token = Some token || current_token = None -> Some Leave
  | Some _ | None -> Option.map (fun _ -> Launch_interrupt) current_token
;;
