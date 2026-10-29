(* The process signals that end a session, recorded by the handlers and read
   by the loop. See the .mli for why a handler records rather than exits. *)

type t = {
  terminate_requested : bool Atomic.t;
  terminate_signal : string Atomic.t;
  interrupt_requested : bool Atomic.t;
  interrupt_armed : bool Atomic.t;
}

let create () =
  {
    terminate_requested = Atomic.make false;
    terminate_signal = Atomic.make "";
    interrupt_requested = Atomic.make false;
    interrupt_armed = Atomic.make false;
  }

let request_terminate t ~signal =
  (* The name first, then the flag: the loop reads the flag and only then the
     name, so a handler that set them the other way could hand the loop a
     terminate with no cause to write down. *)
  Atomic.set t.terminate_signal signal;
  Atomic.set t.terminate_requested true

let terminate_signal t =
  match Atomic.get t.terminate_signal with
  | "" -> None
  | signal -> Some signal
let request_interrupt t = Atomic.set t.interrupt_requested true
let interrupt_pending t = Atomic.get t.interrupt_requested
let withdraw_interrupt t = Atomic.set t.interrupt_armed false

type verdict =
  | Continue
  | Interrupt_armed
  | Interrupt_again
  | Quit

let poll t =
  if Atomic.get t.terminate_requested then Quit
  else if Atomic.exchange t.interrupt_requested false then
    if Atomic.get t.interrupt_armed then Interrupt_again
    else begin
      Atomic.set t.interrupt_armed true;
      Interrupt_armed
    end
  else Continue
