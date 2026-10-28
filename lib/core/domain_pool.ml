type t = {
  pool : Eio.Executor_pool.t;
  domain_count : int;
}

let recommended_domain_count () =
  max 1 (Domain.recommended_domain_count () - 2)

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
let submit ~weight ~name t f =
  Executor_pool_submission.submit t.pool ~weight ~name (fun () ->
    Executor_pool_ref.with_worker_context f)
;;

let submit_io ~name t f = submit ~weight:weight_io ~name t f
;;

let submit_cpu ~name t f = submit ~weight:weight_cpu ~name t f
;;

let submit_io_async ~sw ~name t f =
  Eio.Fiber.fork_promise ~sw (fun () -> submit_io ~name t f)

let submit_cpu_async ~sw ~name t f =
  Eio.Fiber.fork_promise ~sw (fun () -> submit_cpu ~name t f)

let executor_pool t = t.pool
