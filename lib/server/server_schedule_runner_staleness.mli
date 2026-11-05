(** The fleet schedule list stops saying what the runner's newest record gave
    when [stale_after_sec] passes after its newest finished tick without a
    newer one: it says [stale], or [running] for a tick still in flight, whose
    start was not announced. No record marks that moment, so this watch
    announces it. *)

val watch :
  clock:_ Eio.Time.clock ->
  stale_after_sec:float ->
  finished_at:(unit -> float option) ->
  on_deadline:(unit -> unit) ->
  'a
(** Calls [on_deadline] once each time [stale_after_sec] passes after the
    newest finish [finished_at] reports, sleeping until that deadline in
    between. Never returns. *)
