type t = { mutable dispatched : bool }
type ('a, 'refusal) result = Not_sent of 'refusal | Sent of ('a, string) Stdlib.result
let create () = { dispatched = false }
let dispatched t = t.dispatched
let perform t ~preflight ~send =
  match preflight () with
  | Error detail -> Not_sent detail
  | Ok () -> t.dispatched <- true; Sent (send ())
