let shutting_down = Atomic.make false

let mark_shutting_down () = Atomic.set shutting_down true
let is_shutting_down () = Atomic.get shutting_down
