(* The process signals that end a session, recorded by the handlers and read
   by the loop. See the .mli for why a handler records rather than exits. *)

type t = {
  terminate_requested : bool Atomic.t;
  interrupt_requested : bool Atomic.t;
  interrupt_armed : bool Atomic.t;
}

let create () =
  {
    terminate_requested = Atomic.make false;
    interrupt_requested = Atomic.make false;
    interrupt_armed = Atomic.make false;
  }

let request_terminate t = Atomic.set t.terminate_requested true
let request_interrupt t = Atomic.set t.interrupt_requested true
let withdraw_interrupt t = Atomic.set t.interrupt_armed false

type verdict =
  | Continue
  | Interrupt_armed
  | Quit

let poll t =
  if Atomic.get t.terminate_requested then Quit
  else if Atomic.exchange t.interrupt_requested false then
    if Atomic.get t.interrupt_armed then Quit
    else begin
      Atomic.set t.interrupt_armed true;
      Interrupt_armed
    end
  else Continue
