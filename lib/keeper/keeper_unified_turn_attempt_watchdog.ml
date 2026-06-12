(* Per-attempt cancellation observer for a single keeper turn runtime attempt.

   MASC must not create a wall-clock timeout around the whole provider/tool run.
   The only timeout-like boundaries that belong in MASC are admission, queue,
   subprocess/tool-local policies, or provider-stream progress once that can be
   isolated from active tool execution. This wrapper only records cancellation
   that came from outside this boundary.

   The Cancelled re-raise path is the outer catch for cancellations
   that escape the in-band receipt builder in
   [Keeper_agent_run.run_turn]: the inner Cancel handlers all
   re-raise, so without [on_cancelled] the FSM emits Streaming and
   then nothing — the turn silently disappears from the operator's
   timeline. *)

let dispatch
    ~clock:_
    ~keeper_name:_
    ~attempt_watchdog_s:_
    ~on_cancelled
    ~run
  =
  try
    run ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    on_cancelled "external_cancel";
    raise e
;;
