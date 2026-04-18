(** MASC Level 4 Configuration - Externalized Magic Numbers

    Shared numeric tuning helpers and normalized-value wrappers.
    Environment variables override defaults.

    Based on extreme reviewer feedback:
    - Rich Hickey: "Magic numbers are complected configuration"
    - John Carmack: "Hardcoded values prevent tuning"

    @author Second Brain
    @since MASC v3.1 (Level 4)
*)

(** {1 Environment Helpers}

    Thin delegates to the [Env_config_core] SSOT so config reads use the
    same env-var semantics (trim + malformed-value fallback) as the rest
    of the codebase. *)

let get_env_float name default =
  Env_config_core.get_float ~default name

let get_env_int name default =
  Env_config_core.get_int ~default name

(** {1 Random Number Generator} *)

(** Initialize RNG with seed for reproducibility *)
let rng_initialized = ref false

let ensure_rng_init () =
  if not !rng_initialized then begin
    let seed = get_env_int "MASC_RANDOM_SEED" (int_of_float (Time_compat.now () *. 1000.0)) in
    Random.init seed;
    rng_initialized := true
  end

(** Get random float with guaranteed initialization *)
let random_float max =
  ensure_rng_init ();
  Random.float max

(** Get random int with guaranteed initialization *)
let random_int max =
  ensure_rng_init ();
  Random.int max

(** {2 Parameterized RNG}

    Pure functions accept [~rng:Random.State.t] for deterministic testing.
    Use [make_rng ~seed:42 ()] in tests, [make_rng ()] in production.
*)

let make_rng ?seed () =
  let s = match seed with
    | Some s -> s
    | None -> get_env_int "MASC_RANDOM_SEED" (int_of_float (Time_compat.now () *. 1000.0))
  in
  Random.State.make [|s|]

(** {1 Validation} *)

(** Check if float is finite (not NaN or Inf) *)
let is_finite f =
  match classify_float f with
  | FP_normal | FP_subnormal | FP_zero -> true
  | FP_infinite | FP_nan -> false

(** {1 Normalized Type — Parse Don't Validate}

    Abstract type guaranteed to be in [0.0, 1.0].
    Used for fitness, strength, threshold, selection_pressure, mutation_rate, etc.

    - Bartosz Milewski: "Make invalid states unrepresentable"
    - Alexis King: "Parse don't validate"
*)

module Normalized : sig
  type t

  val of_float : float -> t option
  val of_float_clamped : float -> t
  val to_float : t -> float
  val compare : t -> t -> int
  val to_json : t -> Yojson.Safe.t
  val of_json : Yojson.Safe.t -> t option
end = struct
  type t = float

  let of_float f =
    if not (is_finite f) || f < 0.0 || f > 1.0 then None
    else Some f

  let of_float_clamped f =
    if not (is_finite f) then 0.5
    else max 0.0 (min 1.0 f)

  let to_float t = t
  let compare = Float.compare
  let to_json t = `Float t

  let of_json = function
    | `Float f -> of_float f
    | `Int i -> of_float (float_of_int i)
    | _ -> None
end

(** Fitness: Normalized + domain-specific helpers for agent fitness *)
module Fitness : sig
  type t = Normalized.t

  val of_float : float -> t option
  val of_float_clamped : float -> t
  val to_float : t -> float
  val initial : unit -> t
  val combine : t -> t -> t
  val adjust : t -> delta:float -> t
  val compare : t -> t -> int
  val to_json : t -> Yojson.Safe.t
  val of_json : Yojson.Safe.t -> t option
end = struct
  type t = Normalized.t

  let of_float = Normalized.of_float
  let of_float_clamped = Normalized.of_float_clamped
  let to_float = Normalized.to_float
  let compare = Normalized.compare
  let to_json = Normalized.to_json
  let of_json = Normalized.of_json

  let initial () =
    of_float_clamped 0.5

  let combine a b =
    of_float_clamped ((to_float a +. to_float b) /. 2.0)

  let adjust t ~delta =
    of_float_clamped (to_float t +. delta)
end

(** Strength: Normalized alias for pheromone strength *)
module Strength = Normalized

(** Threshold: Normalized alias for quorum thresholds *)
module Threshold = Normalized
