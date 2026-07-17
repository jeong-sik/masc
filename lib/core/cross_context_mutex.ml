type t =
  { eio_gate : Eio.Mutex.t
  ; cross_context_mutex : Stdlib.Mutex.t
  }

let create () =
  { eio_gate = Eio.Mutex.create ()
  ; cross_context_mutex = Stdlib.Mutex.create ()
  }
;;

let rec lock_cooperatively mutex =
  if Stdlib.Mutex.try_lock mutex
  then ()
  else (
    Eio.Fiber.yield ();
    (lock_cooperatively [@tailcall]) mutex)
;;

type cancellation_mode =
  | Cancellable
  | Durable

let with_eio_lock cancellation_mode t f =
  Eio.Mutex.use_ro t.eio_gate (fun () ->
    lock_cooperatively t.cross_context_mutex;
    let run_locked () =
      Fun.protect
        ~finally:(fun () -> Stdlib.Mutex.unlock t.cross_context_mutex)
        f
    in
    match cancellation_mode with
    | Cancellable -> run_locked ()
    | Durable -> Eio.Cancel.protect run_locked)
;;

let with_lock t f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> Stdlib.Mutex.protect t.cross_context_mutex f
  | Eio_guard.Eio_fiber -> with_eio_lock Cancellable t f
;;

let with_durable_lock t f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> Stdlib.Mutex.protect t.cross_context_mutex f
  | Eio_guard.Eio_fiber -> with_eio_lock Durable t f
;;
