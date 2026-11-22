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

let start_worker_pool ~sw domain_mgr =
  Domain_pool.create ~sw ~domain_count:1 (domain_mgr_for Worker domain_mgr)
