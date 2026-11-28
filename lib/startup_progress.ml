type step =
  | Initializing
  | Restoring_records
  | Creating_server_state
  | Installing_keeper_owners
  | Restoring_shutdown_fences
  | Reconciling_keeper_stores
  | Recovering_transcript_tails
  | Closing_open_turns
  | Starting_executors
  | Settling_restarts
  | Activating_owner_state
  | Starting_keeper_loops

let step_to_string = function
  | Initializing -> "initializing"
  | Restoring_records -> "restoring_records"
  | Creating_server_state -> "creating_server_state"
  | Installing_keeper_owners -> "installing_keeper_owners"
  | Restoring_shutdown_fences -> "restoring_shutdown_fences"
  | Reconciling_keeper_stores -> "reconciling_keeper_stores"
  | Recovering_transcript_tails -> "recovering_transcript_tails"
  | Closing_open_turns -> "closing_open_turns"
  | Starting_executors -> "starting_executors"
  | Settling_restarts -> "settling_restarts"
  | Activating_owner_state -> "activating_owner_state"
  | Starting_keeper_loops -> "starting_keeper_loops"
;;

(* Two cells, not one record: [beat] never touches the step, so a beat from
   one domain cannot undo an [enter] from another. A reader that sees a new
   step with the previous time is at most one clock read behind. *)
let step_cell = Atomic.make Initializing
let progress_cell = Atomic.make (Mtime_clock.now ())
let beat () = Atomic.set progress_cell (Mtime_clock.now ())

let enter step =
  Atomic.set step_cell step;
  beat ()
;;

let reset () = enter Initializing
let current_step () = Atomic.get step_cell

let idle_seconds () =
  Mtime.Span.to_float_ns (Mtime.span (Atomic.get progress_cell) (Mtime_clock.now ()))
  /. 1e9
;;

type verdict =
  | Settled
  | Wait of float
  | Stalled of float

let verdict ~stall_seconds ~ready ~idle_seconds =
  if ready
  then Settled
  else if idle_seconds >= stall_seconds
  then Stalled idle_seconds
  else Wait (stall_seconds -. idle_seconds)
;;
