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

(* A pool submit performs Eio effects; from a raw systhread/Domain there is
   no Eio handler and it would raise [Effect.Unhandled]. Guarding here gives
   every caller that runs in both contexts the inline fallback once, instead
   of each call site carrying its own [is_eio_fiber] check (#25158). *)

let submit_io_or_inline f =
  match Atomic.get pool, Eio_guard.execution_context () with
  | Some p, Eio_guard.Eio_fiber -> Domain_pool.submit_io p f
  | Some _, Eio_guard.Non_eio
  | None, (Eio_guard.Eio_fiber | Eio_guard.Non_eio) -> f ()
;;

let submit_cpu_or_inline f =
  match Atomic.get pool, Eio_guard.execution_context () with
  | Some p, Eio_guard.Eio_fiber -> Domain_pool.submit_cpu p f
  | Some _, Eio_guard.Non_eio
  | None, (Eio_guard.Eio_fiber | Eio_guard.Non_eio) -> f ()
;;
