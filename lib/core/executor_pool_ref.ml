(** Executor_pool_ref — Shared reference to the Eio.Executor_pool.

    Set once at server startup in [server_runtime_bootstrap.ml].
    Used by dashboard compute and domain-safe chain adapter offloading.

    [submit_domain_safe_or_inline] is only for pure/domain-safe work that
    does not capture Eio capabilities, shared Eio mutexes, or other
    domain-bound resources.  If the pool is not available (e.g. during
    tests or before server init), the computation runs inline in the
    current fiber. *)

let pool : Eio.Executor_pool.t option ref = ref None

let get () = !pool

let set p = pool := Some p

(** Submit domain-safe pure work to the executor pool if available,
    or run inline otherwise.  The explicit [label] keeps callsites
    auditable when reviewing executor-pool usage. *)
let submit_domain_safe_or_inline ?(weight = 1.0) ~label f =
  match !pool with
  | Some p ->
      (try Eio.Executor_pool.submit_exn p ~weight (fun () ->
         Eio.Switch.run (fun _sw -> f ()))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
           Log.Misc.warn
             "executor_pool submit failed for %s, running inline: %s"
             label (Printexc.to_string exn);
           f ())
  | None -> f ()

let submit_or_inline ?(weight = 1.0) f =
  submit_domain_safe_or_inline ~weight ~label:"unspecified" f
