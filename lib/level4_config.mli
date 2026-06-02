(** MASC Level 4 Configuration — Shared numeric tuning helpers and
    RNG wrappers.

    All reads delegate to {!Env_config_core} so env-var semantics
    (trim + malformed-value fallback) stay consistent with the rest
    of the codebase.

    @since MASC v3.1 (Level 4) *)

(** {1 Environment helpers} *)

(** [get_env_float name default] reads [name] as a float, falling
    back to [default] on missing or malformed values. *)
val get_env_float : string -> float -> float

(** [get_env_int name default] reads [name] as an int, falling back
    to [default] on missing or malformed values. *)
val get_env_int : string -> int -> int

(** {1 Random number generation}

    RNG initialisation is lazy and idempotent. Seed defaults to
    [int_of_float (Time_compat.now () *. 1000.0)] but can be
    overridden via [MASC_RANDOM_SEED] for reproducibility. *)

(** [random_float max] returns a value in [[0.0, max)]. Ensures RNG
    is seeded before first call. *)
val random_float : float -> float

(** [random_int max] returns a value in [[0, max)]. Ensures RNG is
    seeded before first call. *)
val random_int : int -> int
