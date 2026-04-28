(** Budget — Unified envelope for tokens, turns, wall-clock time, cost.

    INTEGRATED §3.1 unifies the divergent budget types from Autonomous
    ([tokens, turns, time]) and Resilience ([tokens, time, cost]) into
    a single superset record. Each module projects only the fields it
    needs for cross-module composition.

    Fields are monotonically decreasing during execution; [is_exhausted]
    treats any non-positive [tokens], [turns], or [time_ms] as terminal.
    [cost_usd] is informational only — it may go negative during accounting
    drift and does not gate execution.

    @stability Evolving
    @since 0.18.9 *)

type t = {
  tokens : int;
  (** LLM tokens (input + output) remaining. 0 = exhausted. *)

  turns : int;
  (** Loop iterations or task invocations remaining. *)

  time_ms : int;
  (** Wall-clock budget remaining in milliseconds. *)

  cost_usd : float;
  (** USD cost cap remaining. May be negative; informational. *)
}

val make : tokens:int -> turns:int -> time_ms:int -> cost_usd:float -> t

val zero : t
(** All gating fields zero; [cost_usd = 0.0]. *)

val is_exhausted : t -> bool
(** [true] iff [tokens <= 0 || turns <= 0 || time_ms <= 0]. *)

val sub_tokens : t -> int -> t

val sub_turns : t -> int -> t

val sub_time_ms : t -> int -> t

val sub_cost_usd : t -> float -> t

val compare : t -> t -> int
(** Lexicographic on [(tokens, turns, time_ms, cost_usd)]. *)

val equal : t -> t -> bool

val to_json : t -> Yojson.Safe.t

val of_json : Yojson.Safe.t -> (t, string) result
