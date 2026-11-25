type role =
  | Ui
  | Io
  | Worker

let minor_heap = function
  | Ui -> Minor_heap.Tuned
  | Io -> Minor_heap.Tuned
  | Worker -> Minor_heap.Tuned

let use_ui_heap () = Minor_heap.apply (minor_heap Ui)

let domain_mgr_for role domain_mgr =
  Minor_heap.domain_mgr (minor_heap role) domain_mgr

let worker_domain_count () =
  Int.max 2 (Int.min 4 (Domain.recommended_domain_count () / 2))

let start_worker_pool ~sw domain_mgr =
  Domain_pool.create ~sw ~domain_count:(worker_domain_count ())
    (domain_mgr_for Worker domain_mgr)
