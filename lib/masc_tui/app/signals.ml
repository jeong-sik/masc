open Masc_tui_core

let interrupt_arm_window_s = 3.0

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

(* Pre-allocated values so POSIX signal handlers do zero allocations. *)
let some_sigterm : string option = Some "SIGTERM"
let some_sighup : string option = Some "SIGHUP"
let sigtstp_noop_handler : Sys.signal_behavior = Sys.Signal_handle (fun _ -> ())

type sigtstp_state =
  | Sigtstp_uninstalled
  | Sigtstp_guarded of Sys.signal_behavior
  | Sigtstp_suspended of Sys.signal_behavior

type t = {
  bell : Wake_bell.t;
  resize_gen : int Atomic.t;
  terminate_sig : string option Atomic.t;
  interrupt_pending : bool Atomic.t;
  interrupt_armed_until : Clock.Mono.t option Atomic.t;
  sigtstp_state : sigtstp_state Atomic.t;
}

let create ~bell =
  {
    bell;
    resize_gen = Atomic.make 0;
    terminate_sig = Atomic.make None;
    interrupt_pending = Atomic.make false;
    interrupt_armed_until = Atomic.make None;
    sigtstp_state = Atomic.make Sigtstp_uninstalled;
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
  (* Catch SIGTSTP while raw mode / alt-screen / Kitty CSI u are active, saving
     the prior disposition so $EDITOR handoff can suspend/resume it cleanly. *)
  (match install_one Sys.sigtstp sigtstp_noop_handler with
  | Some (_, prev) -> Atomic.set t.sigtstp_state (Sigtstp_guarded prev)
  | None -> Atomic.set t.sigtstp_state Sigtstp_uninstalled);
  Eio.Switch.on_release sw (fun () ->
      (match Atomic.exchange t.sigtstp_state Sigtstp_uninstalled with
      | Sigtstp_guarded prev | Sigtstp_suspended prev ->
          restore_one (Sys.sigtstp, prev)
      | Sigtstp_uninstalled -> ());
      List.iter restore_one (List.rev installed))

let suspend_sigtstp_guard t =
  match Atomic.get t.sigtstp_state with
  | Sigtstp_guarded prev as current ->
      if
        Atomic.compare_and_set t.sigtstp_state current (Sigtstp_suspended prev)
      then restore_one (Sys.sigtstp, prev)
  | Sigtstp_suspended _ | Sigtstp_uninstalled -> ()

let resume_sigtstp_guard t =
  match Atomic.get t.sigtstp_state with
  | Sigtstp_suspended prev as current ->
      if Atomic.compare_and_set t.sigtstp_state current (Sigtstp_guarded prev)
      then
        ignore
          (install_one Sys.sigtstp sigtstp_noop_handler
            : (int * Sys.signal_behavior) option)
  | Sigtstp_guarded _ | Sigtstp_uninstalled -> ()

let is_sigtstp_guarded t =
  match Atomic.get t.sigtstp_state with
  | Sigtstp_guarded _ -> true
  | Sigtstp_suspended _ | Sigtstp_uninstalled -> false

let is_armed_at ~now t =
  match Atomic.get t.interrupt_armed_until with
  | Some deadline -> Clock.Mono.compare now deadline < 0
  | None -> false

let expire_interrupt ~now t =
  match Atomic.get t.interrupt_armed_until with
  | Some deadline as current when Clock.Mono.compare now deadline >= 0 ->
      Atomic.compare_and_set t.interrupt_armed_until current None
  | Some _ | None -> false

let poll_exit ?(now = Clock.Mono.now ()) t =
  match Atomic.get t.terminate_sig with
  | Some sig_name -> Terminate sig_name
  | None ->
      ignore (expire_interrupt ~now t : bool);
      if Atomic.exchange t.interrupt_pending false then
        if is_armed_at ~now t then begin
          Atomic.set t.interrupt_armed_until None;
          Interrupt_confirmed
        end
        else begin
          let deadline = Clock.Mono.after_s now interrupt_arm_window_s in
          Atomic.set t.interrupt_armed_until (Some deadline);
          Interrupt_armed
        end
      else Continue

let is_interrupt_armed ?(now = Clock.Mono.now ()) t = is_armed_at ~now t
let interrupt_armed_deadline t = Atomic.get t.interrupt_armed_until
let withdraw_interrupt t = Atomic.set t.interrupt_armed_until None

let clear_interrupts t =
  Atomic.set t.interrupt_pending false;
  Atomic.set t.interrupt_armed_until None
let resize_generation t = Atomic.get t.resize_gen
let terminate_signal t = Atomic.get t.terminate_sig

let pending_signal t =
  Option.is_some (Atomic.get t.terminate_sig)
  || Atomic.get t.interrupt_pending

let exit_reason_of_verdict = function
  | Continue | Interrupt_armed -> None
  | Interrupt_confirmed -> Some Exit_reason.Interrupt
  | Terminate sig_name -> Some (Exit_reason.Terminate sig_name)
