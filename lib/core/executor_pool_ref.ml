(** Executor_pool_ref — Shared reference to the Eio.Executor_pool.

    Set once at server startup in [server_runtime_bootstrap.ml].
    Used by dashboard compute and (future) chain adapter offloading.

    Uses [Atomic.t] rather than a plain [ref] because Executor_pool
    workers run on separate OCaml 5 domains; a plain [ref] provides no
    memory barrier between [set] on the main domain and [get] on a
    worker domain.  [Atomic.get]/[set] give cross-domain visibility.

    [submit_or_inline] provides inline execution outside a usable pool
    context. Accepted work is never replayed. Durable I/O uses
    [submit_strict], which reports a missing pool as a typed error. *)

let pool : Eio.Executor_pool.t option Atomic.t = Atomic.make None

(* Pool work is marked on the fiber that runs it and on the fibers it forks,
   not on its domain. A worker domain runs several jobs at once -- an IO job
   weighs a twentieth of a worker -- and they suspend and end in any order, so
   a per-domain mark cleared when one job ends would unmark another job still
   running there, and that job's nested submit would queue behind the
   capacity it holds. *)
let worker_marker : unit Eio.Fiber.key = Eio.Fiber.create_key ()

let in_worker_context () =
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Option.is_some (Eio.Fiber.get worker_marker)
  | Eio_guard.Non_eio -> false
;;

let with_worker_context f =
  Minor_heap.tune ();
  match Eio_guard.execution_context () with
  | Eio_guard.Eio_fiber -> Eio.Fiber.with_binding worker_marker () f
  | Eio_guard.Non_eio -> f ()
;;

let get () = Atomic.get pool

let set p = Atomic.set pool (Some p)

(* RFC-0204 L3: reads get their own pool, so a read never waits in the FIFO
   queue behind background jobs or runs as a fiber beside them. *)
let read_pool : Eio.Executor_pool.t option Atomic.t = Atomic.make None

let set_read p = Atomic.set read_pool (Some p)

(* The pool a submission from this fiber goes to. Without a read pool a read
   uses the shared pool, so tests and one-pool tools keep a single pool. *)
let selected () =
  match Pool_lane.current () with
  | Pool_lane.Background -> Atomic.get pool
  | Pool_lane.Read ->
    (match Atomic.get read_pool with
     | Some _ as read -> read
     | None -> Atomic.get pool)
;;

module For_testing = struct
  let with_pool_option pool_option f =
    let previous = Atomic.exchange pool pool_option in
    Fun.protect ~finally:(fun () -> Atomic.set pool previous) f
  ;;

  let with_pool p f = with_pool_option (Some p) f

  let with_read_pool p f =
    let previous = Atomic.exchange read_pool (Some p) in
    Fun.protect ~finally:(fun () -> Atomic.set read_pool previous) f
  ;;
end

(** A strict submission never falls back to the caller domain. *)
type strict_submit_error =
  | Pool_unavailable
  | Caller_not_in_eio
  | Work_failed of Eio.Exn.with_bt
  | Submission_failed of Eio.Exn.with_bt

let strict_submit_error_to_string = function
  | Pool_unavailable -> "executor pool is not installed"
  | Caller_not_in_eio -> "executor pool submission requires an Eio fiber"
  | Work_failed (exn, backtrace) ->
    Printf.sprintf
      "executor pool work failed: %s\n%s"
      (Printexc.to_string exn)
      (Printexc.raw_backtrace_to_string backtrace)
  | Submission_failed (exn, backtrace) ->
    Printf.sprintf
      "executor pool submission failed: %s\n%s"
      (Printexc.to_string exn)
      (Printexc.raw_backtrace_to_string backtrace)
;;

let submit_strict ?(weight = 1.0) ~name f =
  match selected (), Eio_guard.execution_context () with
  | None, _ -> Error Pool_unavailable
  | Some _, Eio_guard.Non_eio -> Error Caller_not_in_eio
  | Some p, Eio_guard.Eio_fiber ->
    (try
       Executor_pool_submission.submit p ~weight ~name (fun () ->
         with_worker_context (fun () ->
           Eio.Switch.run (fun _sw ->
             try Ok (f ()) with
             | Eio.Cancel.Cancelled _ as exn ->
               let backtrace = Printexc.get_raw_backtrace () in
               Printexc.raise_with_backtrace exn backtrace
             | exn ->
               let backtrace = Printexc.get_raw_backtrace () in
               Error (Work_failed (exn, backtrace)))))
     with
     | Eio.Cancel.Cancelled _ as exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       Printexc.raise_with_backtrace exn backtrace
     | exn ->
       let backtrace = Printexc.get_raw_backtrace () in
       Error (Submission_failed (exn, backtrace)))
;;

(** Submit [f] to the executor pool if available, or run inline.
    Inline fallback ensures callers work in tests and before server init.
    Re-raises [Eio.Cancel.Cancelled] to preserve structured concurrency. *)
let submit_or_inline ?(weight = 1.0) ~name f =
  match selected (), Eio_guard.execution_context () with
  | Some _, _ when in_worker_context () -> f ()
  | Some p, Eio_guard.Eio_fiber ->
      Executor_pool_submission.submit p ~weight ~name (fun () ->
        with_worker_context (fun () -> Eio.Switch.run (fun _sw -> f ())))
  | (Some _ | None), Eio_guard.Non_eio
  | None, Eio_guard.Eio_fiber -> f ()
