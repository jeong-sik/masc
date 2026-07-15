type t =
  { eio_gate : Eio.Mutex.t
  ; systhread_mutex : Stdlib.Mutex.t
  }

let create () =
  { eio_gate = Eio.Mutex.create ()
  ; systhread_mutex = Stdlib.Mutex.create ()
  }
;;

type execution_context =
  | Eio_fiber
  | Non_eio

let execution_context () =
  match Eio.Fiber.check () with
  | () -> Eio_fiber
  | exception Effect.Unhandled _ -> Non_eio
;;

let rec lock_systhread_mutex_cooperatively mutex =
  if Stdlib.Mutex.try_lock mutex
  then ()
  else (
    Eio.Fiber.yield ();
    lock_systhread_mutex_cooperatively mutex)
;;

type 'a outcome =
  | Returned of 'a
  | Raised of exn * Printexc.raw_backtrace

let with_eio_lock ~durable t f =
  let run () =
    lock_systhread_mutex_cooperatively t.systhread_mutex;
    Fun.protect
      ~finally:(fun () -> Stdlib.Mutex.unlock t.systhread_mutex)
      (fun () -> if durable then Eio.Cancel.protect f else f ())
  in
  let outcome =
    match
      Eio.Mutex.use_ro t.eio_gate run
    with
    | value -> Returned value
    | exception exn -> Raised (exn, Printexc.get_raw_backtrace ())
  in
  if not durable then Eio.Fiber.check ();
  match outcome with
  | Returned value -> value
  | Raised (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace
;;

let with_lock t f =
  match execution_context () with
  | Eio_fiber -> with_eio_lock ~durable:false t f
  | Non_eio -> Stdlib.Mutex.protect t.systhread_mutex f
;;

let with_durable_lock t f =
  match execution_context () with
  | Eio_fiber -> with_eio_lock ~durable:true t f
  | Non_eio -> Stdlib.Mutex.protect t.systhread_mutex f
;;
