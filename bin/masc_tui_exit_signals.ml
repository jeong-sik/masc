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

(* The count comes first: a narrow footer cuts a notice short, and a count
   after "press again to quit" was cut off at 100 columns. *)
let quit_notice ~key ~waiting =
  match waiting with
  | 0 -> Printf.sprintf "%s: press again to quit, or any other key to stay" key
  | 1 ->
    Printf.sprintf
      "%s: 1 unsent message is dropped if you press again to quit, or any other key to stay"
      key
  | n ->
    Printf.sprintf
      "%s: %d unsent messages are dropped if you press again to quit, or any other key to stay"
      key n
