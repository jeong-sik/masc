open Masc_tui_core

type exit_verdict =
  | Continue
  | Interrupt_armed
  | Interrupt_confirmed
  | Terminate of string

let equal_exit_verdict a b =
  match a, b with
  | Continue, Continue
  | Interrupt_armed, Interrupt_armed
  | Interrupt_confirmed, Interrupt_confirmed ->
      true
  | Terminate x, Terminate y -> String.equal x y
  | Continue, (Interrupt_armed | Interrupt_confirmed | Terminate _)
  | Interrupt_armed, (Continue | Interrupt_confirmed | Terminate _)
  | Interrupt_confirmed, (Continue | Interrupt_armed | Terminate _)
  | Terminate _, (Continue | Interrupt_armed | Interrupt_confirmed) ->
      false

(* Pre-allocated option values so POSIX signal handlers do zero allocations. *)
let some_sigterm : string option = Some "SIGTERM"
let some_sighup : string option = Some "SIGHUP"

type t = {
  bell : Wake_bell.t;
  resize_gen : int Atomic.t;
  terminate_sig : string option Atomic.t;
  interrupt_pending : bool Atomic.t;
  interrupt_armed : bool Atomic.t;
}

let create ~bell =
  {
    bell;
    resize_gen = Atomic.make 0;
    terminate_sig = Atomic.make None;
    interrupt_pending = Atomic.make false;
    interrupt_armed = Atomic.make false;
  }

let record_resize t =
  Atomic.incr t.resize_gen;
  Wake_bell.ring_from_signal t.bell Wake_bell.Resize

let record_interrupt t =
  Atomic.set t.interrupt_pending true;
  Wake_bell.ring_from_signal t.bell Wake_bell.Interrupt

let record_terminate_opt t sig_opt =
  ignore (Atomic.compare_and_set t.terminate_sig None sig_opt : bool);
  Wake_bell.ring_from_signal t.bell Wake_bell.Terminate

let record_terminate t ~signal = record_terminate_opt t (Some signal)

let install_one sig_num behavior =
  match Sys.signal sig_num behavior with
  | prev -> Some (sig_num, prev)
  | exception Invalid_argument _ -> None

let restore_one (sig_num, prev) =
  match Sys.set_signal sig_num prev with
  | () -> ()
  | exception Invalid_argument _ -> ()

let install ~sw t =
  Eio.Switch.check sw;
  let installed =
    List.filter_map Fun.id
      [
        install_one Sys.sigpipe Sys.Signal_ignore;
        install_one Sys.sigwinch (Sys.Signal_handle (fun _ -> record_resize t));
        install_one Sys.sigcont (Sys.Signal_handle (fun _ -> record_resize t));
        install_one Sys.sigint (Sys.Signal_handle (fun _ -> record_interrupt t));
        install_one Sys.sigterm
          (Sys.Signal_handle (fun _ -> record_terminate_opt t some_sigterm));
        install_one Sys.sighup
          (Sys.Signal_handle (fun _ -> record_terminate_opt t some_sighup));
      ]
  in
  Eio.Switch.on_release sw (fun () ->
      List.iter restore_one (List.rev installed))

let poll_exit t =
  match Atomic.get t.terminate_sig with
  | Some sig_name -> Terminate sig_name
  | None ->
      if Atomic.exchange t.interrupt_pending false then
        if Atomic.get t.interrupt_armed then Interrupt_confirmed
        else begin
          Atomic.set t.interrupt_armed true;
          Interrupt_armed
        end
      else Continue

let withdraw_interrupt t = Atomic.set t.interrupt_armed false

let clear_interrupts t =
  Atomic.set t.interrupt_pending false;
  Atomic.set t.interrupt_armed false
let resize_generation t = Atomic.get t.resize_gen
let terminate_signal t = Atomic.get t.terminate_sig

let pending_signal t =
  Option.is_some (Atomic.get t.terminate_sig)
  || Atomic.get t.interrupt_pending

let exit_reason_of_verdict = function
  | Continue | Interrupt_armed -> None
  | Interrupt_confirmed -> Some Exit_reason.Interrupt
  | Terminate sig_name -> Some (Exit_reason.Terminate sig_name)
