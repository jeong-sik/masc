(** Executor_pool_ref — Shared reference to the Eio.Executor_pool.

    Set once at server startup in [server_runtime_bootstrap.ml].
    Used by dashboard compute and (future) chain adapter offloading.

    Uses [Atomic.t] rather than a plain [ref] because Executor_pool
    workers run on separate OCaml 5 domains; a plain [ref] provides no
    memory barrier between [set] on the main domain and [get] on a
    worker domain.  [Atomic.get]/[set] give cross-domain visibility.

    [submit_or_inline] provides graceful fallback for non-durable compute.
    Durable I/O must use [submit_strict], which never runs inline or replays
    a closure after a failed submission. *)

let pool : Eio.Executor_pool.t option Atomic.t = Atomic.make None

let worker_depth = Domain.DLS.new_key (fun () -> 0)

let in_worker_context () = Domain.DLS.get worker_depth > 0

let with_worker_context f =
  let previous = Domain.DLS.get worker_depth in
  Domain.DLS.set worker_depth (previous + 1);
  Fun.protect ~finally:(fun () -> Domain.DLS.set worker_depth previous) f
;;

let get () = Atomic.get pool

let set p = Atomic.set pool (Some p)

module For_testing = struct
  let with_pool_option pool_option f =
    let previous = Atomic.exchange pool pool_option in
    Fun.protect ~finally:(fun () -> Atomic.set pool previous) f
  ;;

  let with_pool p f = with_pool_option (Some p) f
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

let submit_strict ?(weight = 1.0) f =
  match Atomic.get pool, Eio_guard.execution_context () with
  | None, _ -> Error Pool_unavailable
  | Some _, Eio_guard.Non_eio -> Error Caller_not_in_eio
  | Some p, Eio_guard.Eio_fiber ->
    (try
       Eio.Executor_pool.submit_exn p ~weight (fun () ->
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
let submit_or_inline ?(weight = 1.0) f =
  match Atomic.get pool, Eio_guard.execution_context () with
  | Some _, _ when in_worker_context () -> f ()
  | Some p, Eio_guard.Eio_fiber ->
      (try Eio.Executor_pool.submit_exn p ~weight (fun () ->
         with_worker_context (fun () -> Eio.Switch.run (fun _sw -> f ())))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Misc.warn "executor_pool submit failed, running inline: %s"
             (Printexc.to_string exn);
           f ())
  | (Some _ | None), Eio_guard.Non_eio
  | None, Eio_guard.Eio_fiber -> f ()
