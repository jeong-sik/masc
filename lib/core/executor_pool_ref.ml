(** Executor_pool_ref — Shared reference to the Eio.Executor_pool.

    Set once at server startup in [server_runtime_bootstrap.ml].
    Used by dashboard compute and (future) chain adapter offloading.

    [submit_or_inline] provides graceful fallback: if the pool is not
    available (e.g. during tests or before server init), the computation
    runs inline in the current fiber. *)

let pool : Eio.Executor_pool.t option ref = ref None

let get () = !pool

let set p = pool := Some p

(** Submit [f] to the executor pool if available, or run inline.
    Inline fallback ensures callers work in tests and before server init.
    Re-raises [Eio.Cancel.Cancelled] to preserve structured concurrency. *)
let submit_or_inline ?(weight = 1.0) f =
  match !pool with
  | Some p ->
      (try Eio.Executor_pool.submit_exn p ~weight (fun () ->
         Eio.Switch.run (fun _sw -> f ()))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Misc.warn "executor_pool submit failed, running inline: %s"
             (Printexc.to_string exn);
           f ())
  | None -> f ()
