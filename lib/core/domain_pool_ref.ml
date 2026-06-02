(** Domain_pool_ref — shared typed reference to the process Domain_pool. *)

let pool : Domain_pool.t option Atomic.t = Atomic.make None

let get () = Atomic.get pool

let set p = Atomic.set pool (Some p)

let clear_for_tests () = Atomic.set pool None

let domain_count_opt () =
  match Atomic.get pool with
  | None -> None
  | Some p -> Some (Domain_pool.domain_count p)
;;

let submit_io_or_inline f =
  match Atomic.get pool with
  | Some p -> Domain_pool.submit_io p f
  | None -> f ()
;;

let submit_cpu_or_inline f =
  match Atomic.get pool with
  | Some p -> Domain_pool.submit_cpu p f
  | None -> f ()
;;
