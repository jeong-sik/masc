(** Process-wide Stdlib.Random helpers.

    This module is intentionally small: it owns lazy process RNG seeding
    from [MASC_RANDOM_SEED], then delegates random draws to [Stdlib.Random].
    It is not an application "level" or a general configuration layer. *)

(** Initialize RNG with seed for reproducibility *)
let rng_uninitialized = 0
let rng_initializing = 1
let rng_initialized = 2

let rng_state = Atomic.make rng_uninitialized

let ensure_rng_init () =
  let rec loop () =
    match Atomic.get rng_state with
    | state when state = rng_initialized -> ()
    | state when state = rng_uninitialized ->
      if Atomic.compare_and_set rng_state rng_uninitialized rng_initializing
      then (
        try
          let seed =
            Env_config_core.get_int
              ~default:(int_of_float (Time_compat.now () *. 1000.0))
              "MASC_RANDOM_SEED"
          in
          (* NDT-OK: process-wide RNG seeding boundary; deterministic callers
             set [MASC_RANDOM_SEED] before first use. *)
          Random.init seed;
          Atomic.set rng_state rng_initialized
        with
        | exn ->
          Atomic.set rng_state rng_uninitialized;
          raise exn)
      else loop ()
    | state when state = rng_initializing ->
      Domain.cpu_relax ();
      loop ()
    | _ -> ()
  in
  loop ()

(** Get random float with guaranteed initialization *)
let random_float max =
  ensure_rng_init ();
  Random.float max

(** Get random int with guaranteed initialization *)
let random_int max =
  ensure_rng_init ();
  Random.int max

module For_testing = struct
  let reset_rng_state () = Atomic.set rng_state rng_uninitialized
  let rng_state () = Atomic.get rng_state
  let initialized_state = rng_initialized
end
