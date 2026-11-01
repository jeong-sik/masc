type t = bool Atomic.t

let create () = Atomic.make false

let run slot work =
  if not (Atomic.compare_and_set slot false true) then
    Error "Previous Board image is still preparing; retry after it finishes"
  else Fun.protect work ~finally:(fun () -> Atomic.set slot false)
