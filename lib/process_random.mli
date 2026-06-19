(** Process-wide Stdlib.Random helpers.

    RNG initialization is lazy and idempotent. Seed defaults to
    [int_of_float (Time_compat.now () *. 1000.0)] but can be
    overridden via [MASC_RANDOM_SEED] for reproducibility. *)

(** [random_float max] returns a value in [[0.0, max)]. It ensures RNG
    is seeded before first call. *)
val random_float : float -> float

(** [random_int max] returns a value in [[0, max)]. It ensures RNG is
    seeded before first call. *)
val random_int : int -> int

module For_testing : sig
  val reset_rng_state : unit -> unit
  val rng_state : unit -> int
  val initialized_state : int
end
