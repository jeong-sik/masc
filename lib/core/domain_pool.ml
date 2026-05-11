type t = {
  pool : Eio.Executor_pool.t;
  domain_count : int;
}

let recommended_domain_count () =
  max 2 (Domain.recommended_domain_count () - 1)

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

let submit_io t f = Eio.Executor_pool.submit_exn t.pool ~weight:weight_io f

let submit_cpu t f = Eio.Executor_pool.submit_exn t.pool ~weight:weight_cpu f

let submit_io_async ~sw t f =
  Eio.Executor_pool.submit_fork ~sw t.pool ~weight:weight_io f

let submit_cpu_async ~sw t f =
  Eio.Executor_pool.submit_fork ~sw t.pool ~weight:weight_cpu f

let executor_pool t = t.pool
