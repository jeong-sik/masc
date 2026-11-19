(* [state_mu] only protects [locked] and [os_cond] signaling. It is never held
   across user callbacks, Eio yields, or [Eio.Condition.broadcast], preventing
   OS-thread blocking inside Eio and eliminating polling loops. *)
type t =
  { state_mu : Stdlib.Mutex.t
  ; mutable locked : bool
  ; os_cond : Stdlib.Condition.t
  ; eio_cond : Eio.Condition.t
  }

let create () =
  { state_mu = Stdlib.Mutex.create ()
  ; locked = false
  ; os_cond = Stdlib.Condition.create ()
  ; eio_cond = Eio.Condition.create ()
  }
;;

let try_acquire t =
  Stdlib.Mutex.lock t.state_mu;
  let acquired =
    if t.locked
    then false
    else (
      t.locked <- true;
      true)
  in
  Stdlib.Mutex.unlock t.state_mu;
  acquired
;;

let acquire_non_eio t =
  Stdlib.Mutex.lock t.state_mu;
  Fun.protect
    ~finally:(fun () -> Stdlib.Mutex.unlock t.state_mu)
    (fun () ->
       while t.locked do
         Stdlib.Condition.wait t.os_cond t.state_mu
       done;
       t.locked <- true)
;;

let acquire_eio t =
  Eio.Condition.loop_no_mutex t.eio_cond (fun () ->
    if try_acquire t then Some () else None)
;;

let release t =
  Stdlib.Mutex.lock t.state_mu;
  t.locked <- false;
  Stdlib.Condition.signal t.os_cond;
  Stdlib.Mutex.unlock t.state_mu;
  Eio.Condition.broadcast t.eio_cond
;;

type cancellation_mode =
  | Cancellable
  | Durable

let with_eio_lock cancellation_mode t f =
  acquire_eio t;
  let run_locked () = Fun.protect ~finally:(fun () -> release t) f in
  match cancellation_mode with
  | Cancellable -> run_locked ()
  | Durable -> Eio.Cancel.protect run_locked
;;

let with_non_eio_lock t f =
  acquire_non_eio t;
  Fun.protect ~finally:(fun () -> release t) f
;;

let with_lock t f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> with_non_eio_lock t f
  | Eio_guard.Eio_fiber -> with_eio_lock Cancellable t f
;;

let with_durable_lock t f =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> with_non_eio_lock t f
  | Eio_guard.Eio_fiber -> with_eio_lock Durable t f
;;

let try_with_lock t f =
  if try_acquire t
  then Some (Fun.protect ~finally:(fun () -> release t) f)
  else None
;;
