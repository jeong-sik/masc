type t = bool Atomic.t

let create () = Atomic.make false

let is_busy slot = Atomic.get slot
let try_acquire slot = Atomic.compare_and_set slot false true
let release slot = Atomic.set slot false

let run slot work =
  if not (try_acquire slot) then
    Error "Previous Board image is still preparing; retry after it finishes"
  else Fun.protect work ~finally:(fun () -> release slot)
