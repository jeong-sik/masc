type t = { mutable ready : bool }
let create () = {ready=false}
let observe_frame t ~visible ~input_pending =
  t.ready <- visible && not input_pending
let ready t = t.ready
let withdraw t = t.ready <- false
