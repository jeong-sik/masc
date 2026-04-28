(** Timestamp — Unix epoch seconds (UTC).

    Standardized on [float] across all new modules per INTEGRATED §5
    Decision 2. Multimodal converts to [Ptime.t] internally if needed,
    but exposes {!t} in its public surface.

    Use [now] sparingly: deterministic cores (Keeper FSM, Autonomous
    state transitions) must take [now : float] as an explicit argument
    rather than calling {!now} directly, to preserve testability and
    TLA+ refinement.

    @stability Evolving
    @since 0.18.9 *)

type t = float
(** Unix epoch in seconds (UTC). *)

val now : unit -> t
(** [Unix.gettimeofday ()]. Side-effecting. Avoid in pure cores. *)

val of_float : float -> t

val to_float : t -> float

val compare : t -> t -> int

val equal : t -> t -> bool

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
