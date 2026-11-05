let observer : (masc_root:string -> unit) Atomic.t = Atomic.make (fun ~masc_root:_ -> ())
let install observer_fn = Atomic.set observer observer_fn
let appended ~masc_root = (Atomic.get observer) ~masc_root
