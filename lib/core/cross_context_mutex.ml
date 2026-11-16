type t =
  { eio_gate : Eio.Mutex.t
  ; cross_context_mutex : Stdlib.Mutex.t
  }

let create () =
  { eio_gate = Eio.Mutex.create ()
  ; cross_context_mutex = Stdlib.Mutex.create ()
  }
;;

let cooperative_yield spins =
  if spins < 4
  then Eio.Fiber.yield ()
  else (
    try Eio_unix.sleep 0.001 with
    | Effect.Unhandled _ -> Eio.Fiber.yield ())
;;

let rec lock_cooperatively mutex spins =
  if Stdlib.Mutex.try_lock mutex
  then ()
  else (
    cooperative_yield spins;
    (lock_cooperatively [@tailcall]) mutex (spins + 1))
;;

type cancellation_mode =
  | Cancellable
  | Durable

(* Explicit [Eio.Mutex.lock] + [Fun.protect ~finally:Eio.Mutex.unlock] provides
   exclusive fiber mutual exclusion without [use_rw]'s exception poisoning, and
   releases both gates in strict reverse order when the callback raises. *)
let with_eio_lock cancellation_mode t f =
  Eio.Mutex.lock t.eio_gate;
  Fun.protect
    ~finally:(fun () -> Eio.Mutex.unlock t.eio_gate)
    (fun () ->
       lock_cooperatively t.cross_context_mutex 0;
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

let try_with_lock t f =
  let with_stdlib_mutex () =
    if Stdlib.Mutex.try_lock t.cross_context_mutex
    then Some (Fun.protect ~finally:(fun () -> Stdlib.Mutex.unlock t.cross_context_mutex) f)
    else None
  in
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> with_stdlib_mutex ()
  | Eio_guard.Eio_fiber ->
    if Eio.Mutex.try_lock t.eio_gate
    then Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.eio_gate) with_stdlib_mutex
    else None
;;
