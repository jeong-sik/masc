(* Goal tree/detail projections depend on both goal state and the latest
   measurement snapshot. This process-local generation changes only after a
   successful primary write to either store. *)
let value = Atomic.make 0
let current () = Atomic.get value
(* See current: observers need the new generation, not the previous count. *)
let advance () = ignore (Atomic.fetch_and_add value 1)
