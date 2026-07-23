(** Executor_pool_ref — Shared reference to the Eio.Executor_pool.

    Set once at server startup in [server_runtime_bootstrap.ml].
    Used by dashboard compute and (future) chain adapter offloading.

    Uses [Atomic.t] rather than a plain [ref] because Executor_pool
    workers run on separate OCaml 5 domains; a plain [ref] provides no
    memory barrier between [set] on the main domain and [get] on a
    worker domain.  [Atomic.get]/[set] give cross-domain visibility.

    [submit_or_inline] provides graceful fallback: if the pool is not
    available (e.g. during tests or before server init), the computation
    runs inline in the current fiber. *)

let pool : Eio.Executor_pool.t option Atomic.t = Atomic.make None

let get () = Atomic.get pool

let set p = Atomic.set pool (Some p)

(** Submit [f] to the executor pool if available, or run inline.
    Inline fallback ensures callers work in tests and before server init.
    Re-raises [Eio.Cancel.Cancelled] to preserve structured concurrency. *)
let submit_or_inline ?(weight = 1.0) f =
  match Atomic.get pool, Eio_guard.execution_context () with
  | Some p, Eio_guard.Eio_fiber ->
      (try Eio.Executor_pool.submit_exn p ~weight (fun () ->
         Eio.Switch.run (fun _sw -> f ()))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Misc.warn "executor_pool submit failed, running inline: %s"
             (Printexc.to_string exn);
           f ())
  | (Some _ | None), Eio_guard.Non_eio
  | None, Eio_guard.Eio_fiber -> f ()
