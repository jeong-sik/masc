let observer : (unit -> unit) Atomic.t = Atomic.make (fun () -> ())

let install next = Atomic.set observer next

let notify () = (Atomic.get observer) ()

let store ~equal cell value = if not (equal (Atomic.exchange cell value) value) then notify ()
