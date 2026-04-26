(** Keeper Behavioral Regime — pure projection (7th FSM axis MVP).

    Projects a keeper's {b observable signals} into a derived
    behavioral regime — distinct from the 6 mechanical FSM axes
    (KSM/KTC/KDP/KCL/KMC/KCB) which capture "where in the code".

    This axis answers the orthogonal question: "what mode is the
    keeper actually in?" (research basis: Anthropic persona vectors,
    Jason Wei CS25 V4 emergent-capability cliffs, Fowler circuit
    breaker.)

    Contract (mirrors [Keeper_composite_observer]):
    - Pure read. No mutation, no I/O, no event emission.
    - Does not read provider names, token counts, or context bytes —
      those belong to OAS (see [feedback_masc-oas-layer-boundary]).
    - Takes a {b minimal} input record {!input} rather than the full
      [Keeper_registry.registry_entry]. The wrapper in
      [Dashboard_behavioral_regime] handles projection from the
      registry entry; this keeps the deriver trivially testable and
      framework-free (Alexis King, "Parse don't validate").

    MVP scope: 3 regimes derived from turn-failure counter + restart
    history + per-tool failure aggregates. Phase 2 adds Ruminating /
    Avoiding / Saturated / Echoing once richer telemetry hooks exist.

    @since RFC-0003 Phase 3 — 7th axis. *)

(** Regime values are ordered by precedence (highest first). When
    multiple rules fire simultaneously, the highest-precedence one
    wins. Rationale: Jason Wei's "emergent capability cliff" framing
    — regime transition is discrete, not gradient-interpolated, so a
    single-value enum is closer to the phenomenon than a boolean
    vector of independent flags. *)
type regime =
  | Crashing
  (** Lifecycle instability — restart count elevated in a recent
          window. Highest precedence because a crashing keeper cannot
          meaningfully thrash. *)
  | Thrashing
  (** Repeated failure without recovery — turn failures or per-tool
          failure saturation. Analog of Fowler circuit-breaker pre-trip
          at the turn level rather than per-call. *)
  | Healthy (** None of the above. Default. *)

val all_regimes : regime list
val regime_of_string : string -> regime option
val string_of_regime : regime -> string

(** A single tool's aggregate usage. Mirrors the shape of
    [Keeper_types.tool_call_entry] but is declared here so the
    deriver does not depend on that module directly. *)
type tool_aggregate =
  { count : int
  ; failures : int
  }

(** Minimal input the deriver needs. All fields are the caller's
    responsibility to project from whatever stateful source
    (registry entry, replay log, test fixture). *)
type input =
  { turn_consecutive_failures : int
  ; restart_count : int
  ; last_restart_ts : float (** Unix seconds; 0.0 when the keeper has never restarted. *)
  ; tool_aggregates : (string * tool_aggregate) list
    (** One entry per tool the keeper has invoked. Empty list when
          no tool has been used yet. *)
  }

(** Reason carries {b why} the deriver picked this regime. The dashboard
    hub panel surfaces it verbatim so an operator can see which rule
    fired and on what values — no guesswork. *)
type reason =
  { rule_id : string (** Short stable identifier (e.g. ["turn_fail_streak"]). *)
  ; evidence : string list
    (** Concrete values that made the rule fire — already
          human-readable. *)
  }

type snapshot =
  { regime : regime
  ; reason : reason
    (** Empty evidence + [rule_id = "default_healthy"] when
          [regime = Healthy]. *)
  ; updated_at : float
  }

(** Apply the regime rules in precedence order and return the first
    match (or [Healthy] when none match). [now] is injected so the
    deriver stays pure and deterministic. *)
val derive : now:float -> input -> snapshot

(** Stable wire format. Shape:

    {[
      {
        "regime": "thrashing",
        "rule_id": "turn_fail_streak",
        "evidence": [ "turn_consecutive_failures=5" ],
        "updated_at": 1234567890.12
      }
    ]}
*)
val snapshot_to_json : snapshot -> Yojson.Safe.t

(** {1 Thresholds}

    Tunable constants. Defaults are conservative; revisit after
    2-week empirical observation (plan {e Track C}:
    empirical-before-design). *)

val turn_fail_streak_threshold : int
val recent_restart_window_sec : float
val recent_restart_count_threshold : int
val tool_failure_count_threshold : int
val tool_failure_ratio_threshold : float
