type t
type receipt

type outcome =
  | Empty
  | Busy
  | Flushed of
      { rows : int
      ; cleanup_failure : Fs_compat.private_jsonl_operation_failure option
      }
  | Retryable_failure of Trajectory_persistence.issue
  | Indeterminate_failure of Trajectory_persistence.issue
  | Blocked of Trajectory_persistence.issue

val acquire : owner:Trajectory_write_observation.owner -> path:string -> t
(** The first writer of an exact trace retains its original owner. A later
    global source re-init cannot reattribute its buffered flush. *)
val release : t -> unit
val enqueue : t -> Yojson.Safe.t -> receipt
val is_durable : receipt -> bool
val depth : t -> int
val flush : t -> outcome
val flush_all : unit -> (t * outcome) list
val outcome_label : outcome -> string

(** A writer is shared by every still-owned accumulator of the exact trace
    path, including later turns while an earlier finalization is pending.
    Accepted FIFO rows stay in memory until durable acknowledgement. An
    ambiguous write blocks that trace's writer and is never blindly retried. *)

module For_testing : sig
  val acquire_with_append :
    owner:Trajectory_write_observation.owner ->
    append:(path:string -> Yojson.Safe.t list -> Trajectory_persistence.outcome) ->
    path:string -> t
end
