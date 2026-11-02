type t = { mutex : Mutex.t; changed : Condition.t; mutable active : bool; mutable stopping : bool }

let create () = {mutex=Mutex.create ();changed=Condition.create ();active=false;stopping=false}

let with_lock slot f =
  Mutex.lock slot.mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock slot.mutex) f

let is_busy slot = with_lock slot (fun () -> slot.active)
let try_acquire slot = with_lock slot (fun () ->
  if slot.active || slot.stopping then false else (slot.active <- true; true))
let release slot = with_lock slot (fun () ->
  slot.active <- false;
  Condition.broadcast slot.changed)
let stop slot = with_lock slot (fun () -> slot.stopping <- true)
let await_stopped slot = with_lock slot (fun () ->
  while slot.active do Condition.wait slot.changed slot.mutex done)

let run slot work =
  if not (try_acquire slot) then
    Error "Previous Board attachment is still preparing; retry after it finishes"
  else Fun.protect work ~finally:(fun () -> release slot)
