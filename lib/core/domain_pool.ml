type t = {
  pool : Eio.Executor_pool.t;
  domain_count : int;
}

(* RFC-0204 §3.5. An unqueued read handler finishes in a few ms (gate/keepers
   detailed=false at 4 ms on 2026-10-27), and the TUI sends a handful at
   once, so two domains keep reads from waiting on each other; a host with
   fewer than [cores_for_two_read_domains] cores gives one. The read pool
   comes out of the shared pool's share, because more domains than cores
   lengthen every stop-the-world minor collection. *)
let cores_for_two_read_domains = 8

let read_domain_count () =
  if Domain.recommended_domain_count () >= cores_for_two_read_domains then 2 else 1

let recommended_domain_count () =
  max 1 (Domain.recommended_domain_count () - 2 - read_domain_count ())

let weight_io = 0.05
let weight_cpu = 1.0

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

(* Every job also runs marked as pool work. The process-wide submits
   ([Domain_pool_ref.submit_*_or_inline], [Executor_pool_ref.submit_or_inline])
   run inline when the caller is already pool work. Without the mark a job
   that called one of them queued a second job and waited for it: on a
   one-domain pool, or whenever every worker held such a job, nothing was
   left to run the second job, and the workers waited forever. Entering
   the mark also gives the domain the tuned minor heap ([Minor_heap]). *)
let submit ~weight t f =
  Executor_pool_submission.submit t.pool ~weight (fun () ->
    Executor_pool_ref.with_worker_context f)
;;

let submit_io t f = submit ~weight:weight_io t f
;;

let submit_cpu t f = submit ~weight:weight_cpu t f
;;

let submit_io_async ~sw t f =
  Eio.Fiber.fork_promise ~sw (fun () -> submit_io t f)

let submit_cpu_async ~sw t f =
  Eio.Fiber.fork_promise ~sw (fun () -> submit_cpu t f)

let executor_pool t = t.pool
