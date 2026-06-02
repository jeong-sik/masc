(** Confidence — Defensive-normalized [0.0, 1.0] scalar.

    Constructed only via {!make}, which clamps any out-of-range input to
    the valid interval. The internal representation is private to enforce
    the invariant: code that pattern-matches on a {!t} cannot accidentally
    see a [1.5] or [-0.3] value.

    Decision rationale (INTEGRATED §5 Decision 3): eliminating raw [float]
    confidence at the type boundary kills the "confidence > 1.0" bug
    class that would corrupt downstream Resilience confidence evaluation.

    @stability Evolving
    @since 0.18.9 *)

type t
(** Abstract confidence value in [0.0, 1.0]. *)

val make : float -> t
(** [make raw] clamps [raw] to [0.0, 1.0]. NaN is mapped to [0.0]. *)

val to_float : t -> float
(** Extract the underlying float for serialization or display.
    Prefer the combinators below for composition. *)

val zero : t
(** [make 0.0]. *)

val one : t
(** [make 1.0]. *)

val combine : t -> t -> t
(** Geometric mean: [sqrt(a *. b)]. Used to compose independent
    confidence sources (e.g. verifier × producer). *)

val compare : t -> t -> int

val equal : t -> t -> bool

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
