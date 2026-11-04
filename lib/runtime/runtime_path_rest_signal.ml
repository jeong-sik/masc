let observer : (unit -> unit) Atomic.t = Atomic.make ignore
let install observer_fn = Atomic.set observer observer_fn
let recorded () = (Atomic.get observer) ()
