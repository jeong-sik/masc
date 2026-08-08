(** Application-lifetime parallel execution capability.

    The caller owns [sw], selects [domain_count] from its single host resource
    policy, and shares the resulting handle across every execution lane. Raw
    {!Eio.Executor_pool.t} access is intentionally not exposed. *)

type t
type create_error = Non_positive_domain_count of int

type stats =
  { pool_requested : int
  ; reentrant_inline : int
  ; caller_cancelled : int
  }

val create
  :  sw:Eio.Switch.t
  -> domain_mgr:_ Eio.Domain_manager.t
  -> domain_count:int
  -> (t, create_error) result

val create_error_to_string : create_error -> string
val pp_create_error : Format.formatter -> create_error -> unit
val stats : t -> stats

(** Internal execution boundary hidden by the top-level {!Agent_sdk} export.
    A job that re-enters the same runtime from one of its worker fibers runs
    inline on that worker. This is an explicit structural case, not a fallback
    to the caller/server domain, and prevents a full-pool nested-submit
    deadlock. *)
module Private : sig
  exception Caller_cancelled
  exception Runtime_released

  type run_failure =
    { exception_ : exn
    ; backtrace : Printexc.raw_backtrace option
    }

  val check_cancellation : t -> unit
  val run_cpu : t -> (unit -> 'a) -> ('a, run_failure) result
end
