(** Monotonic nanosecond clock for frame budgets, staleness, and replay timing.

    Pure helpers accept explicit timestamps so the TEA store and unit tests run
    deterministically without querying wall-clock or OS timers. *)

module Mono : sig
  type t

  val zero : t
  val of_ns : int64 -> t
  val to_ns : t -> int64
  val now : unit -> t

  val add_ns : t -> int64 -> t
  (** Saturating addition of a non-negative nanosecond offset. *)

  val after_s : t -> float -> t
  (** [after_s at seconds] returns [at] advanced by [max 0. seconds], saturating
      at [Int64.max_int]. Non-finite or negative durations return [at]. *)

  val after_ms : t -> int -> t
  (** [after_ms at ms] advances [at] by [max 0 ms] milliseconds. *)

  val sub_ns : t -> since:t -> int64
  (** Signed nanosecond difference [t - since]. *)

  val seconds_since : t -> since:t -> float
  val ms_since : t -> since:t -> float
  val us_since : t -> since:t -> int

  val of_wall : now:t -> wall_now:float -> float -> t
  (** Project a future wall-clock Unix timestamp onto the monotonic clock using
      only the remaining delta from [wall_now]. *)

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val min : t -> t -> t
  val max : t -> t -> t
end
