type t = {
  pool : Eio.Executor_pool.t;
  domain_count : int;
}

let recommended_domain_count () =
  max 1 (Domain.recommended_domain_count () - 2)

let weight_io = 0.05
let weight_cpu = 1.0

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
   [Eio.Executor_pool.create] has no per-domain entry hook. Every unit of
   work goes through one of the submits below, so each domain pays the
   check once and the resize once. [Gc.get] is a read of the domain's own
   state, not a barrier. *)
let tuned_minor_heap_words = 4 * 1024 * 1024

let tune_minor_heap () =
  let control = Gc.get () in
  if control.Gc.minor_heap_size < tuned_minor_heap_words
  then Gc.set { control with Gc.minor_heap_size = tuned_minor_heap_words }
;;

let with_tuned_minor_heap f =
  tune_minor_heap ();
  f ()
;;

let create ~sw ?domain_count dm =
  let domain_count =
    match domain_count with
    | None -> recommended_domain_count ()
    | Some n when n >= 1 -> n
    | Some n ->
        invalid_arg
          (Printf.sprintf
             "Domain_pool.create: domain_count must be >= 1, got %d" n)
  in
  let pool = Eio.Executor_pool.create ~sw ~domain_count dm in
  { pool; domain_count }

let domain_count t = t.domain_count

let submit_io t f =
  Eio.Executor_pool.submit_exn t.pool ~weight:weight_io (fun () ->
    with_tuned_minor_heap f)
;;

let submit_cpu t f =
  Eio.Executor_pool.submit_exn t.pool ~weight:weight_cpu (fun () ->
    with_tuned_minor_heap f)
;;

let submit_io_async ~sw t f =
  Eio.Executor_pool.submit_fork ~sw t.pool ~weight:weight_io (fun () ->
    with_tuned_minor_heap f)

let submit_cpu_async ~sw t f =
  Eio.Executor_pool.submit_fork ~sw t.pool ~weight:weight_cpu (fun () ->
    with_tuned_minor_heap f)

let executor_pool t = t.pool
