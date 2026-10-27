type job =
  | Job :
      { work : unit -> 'a
      ; label : string option
      ; finished : ('a, exn * Printexc.raw_backtrace) result Eio.Promise.u
      }
      -> job

(* Unbounded, as [Eio_unix.run_in_systhread] is: adding never waits. *)
let jobs : job Eio.Stream.t = Eio.Stream.create max_int
let started = Atomic.make false

(* Each job gets its own fiber at once, so a long one never delays the next.
   The fiber catches everything the work raises; nothing else can end the
   loop, and nothing cancels the host. *)
let serve () =
  Domain_pool.tune_minor_heap ();
  Eio_main.run (fun _env ->
    Eio.Switch.run (fun sw ->
      let rec loop () =
        let (Job { work; label; finished }) = Eio.Stream.take jobs in
        Eio.Fiber.fork ~sw (fun () ->
          let result =
            match Eio_unix.run_in_systhread ?label work with
            | value -> Ok value
            | exception exn -> Error (exn, Printexc.get_raw_backtrace ())
          in
          Eio.Promise.resolve finished result);
        loop ()
      in
      loop ()))
;;

let start () =
  if Atomic.compare_and_set started false true then ignore (Domain.spawn serve : unit Domain.t)
;;

let run ?label work =
  match Eio_guard.execution_context () with
  | Eio_guard.Non_eio -> work ()
  | Eio_guard.Eio_fiber when Executor_pool_ref.in_worker_context () || not (Atomic.get started) ->
    Eio_unix.run_in_systhread ?label work
  | Eio_guard.Eio_fiber ->
    Eio.Fiber.check ();
    let result, finished = Eio.Promise.create () in
    Eio.Stream.add jobs (Job { work; label; finished });
    (match Eio.Cancel.protect (fun () -> Eio.Promise.await result) with
     | Ok value -> value
     | Error (exn, backtrace) -> Printexc.raise_with_backtrace exn backtrace)
;;
