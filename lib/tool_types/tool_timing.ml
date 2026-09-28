type started = float

let start () = Time_compat.now ()
let started_at started = started
let elapsed_ms started = (Time_compat.now () -. started) *. 1000.0
