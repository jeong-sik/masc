(* The tuned minor heap, applied on the domain that runs the work.

   [Gc.set]'s minor_heap_size is per-domain in OCaml 5: it resizes the
   caller's minor heap and says nothing about domains that start later.
   Measured 2026-09-05 -- a domain spawned after a 4M-word set reports the
   2M-word default. So the tuning in [main_eio.ml], which the comment in
   [server_runtime_bootstrap.ml] names as the single source, reached one
   domain out of fifteen: the live server ran its pool on the default.

   That matters more than the frequency it was meant to cut. A minor
   collection is a stop-the-world barrier across every domain, so a pool
   domain collecting eight times as often stops the whole server eight
   times as often. Measured on this machine with fourteen allocating
   domains: p99 of a quiet domain's work was 169 us with four of them and
   11 ms with fourteen.

   Set on the domain rather than at pool creation because
   [Eio.Executor_pool.create] has no per-domain entry hook. Every job of a
   masc pool ([Domain_pool], [Executor_pool_ref]) enters through
   [Executor_pool_ref.with_worker_context], so each of their domains pays the
   check once and the resize once. Agent Core's codec pool submits raw jobs
   and is not covered. [Gc.get] is a read of
   the domain's own state, not a barrier. *)
let tuned_words = 4 * 1024 * 1024

let tune () =
  let control = Gc.get () in
  if control.Gc.minor_heap_size < tuned_words
  then Gc.set { control with Gc.minor_heap_size = tuned_words }
;;
