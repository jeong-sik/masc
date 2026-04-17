(** Keeper Behavioral Regime — pure projection (7th FSM axis MVP).

    Projects a [Keeper_registry.registry_entry] into a {b derived}
    behavioral regime — distinct from the 6 mechanical FSM axes
    (KSM/KTC/KDP/KCL/KMC/KCB) which capture "where in the code".

    This axis answers the orthogonal question: "what mode is the
    keeper actually in?" Example regimes (research basis: Anthropic
    persona vectors, Jason Wei CS25 V4 emergent-capability cliffs,
    Fowler circuit breaker, Reflexion rumination spiral).

    Contract (mirrors [Keeper_composite_observer]):
    - Pure read. No mutation, no I/O, no event emission.
    - Does not read provider names, token counts, or context bytes —
      those belong to OAS (see [feedback_masc-oas-layer-boundary]).
    - Only consumes fields already materialised on [registry_entry].

    MVP scope: 3 regimes derived from turn-failure counter + restart
    history + tool-usage aggregates. Phase 2 adds Ruminating /
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
          window. Highest precedence because it subsumes downstream
          regimes (a crashing keeper cannot meaningfully thrash). *)
  | Thrashing
      (** Repeated failure without recovery — turn failures or per-tool
          failure saturation. Analog of Fowler circuit-breaker pre-trip
          but at the turn level rather than per-call. *)
  | Healthy
      (** None of the above. Default. *)

val all_regimes : regime list
(** Enumeration of all regime values in precedence order. Used by
    the dashboard to build a stable column header. *)

val regime_of_string : string -> regime option
(** [regime_of_string s] parses a canonical lowercase name. Returns
    [None] when [s] does not match any declared regime. *)

val string_of_regime : regime -> string
(** [string_of_regime r] returns the canonical lowercase name. Stable
    wire format — the dashboard and TLA+ spec both depend on it. *)

(** Reason carries {b why} the deriver picked this regime. The dashboard
    hub panel surfaces it verbatim so an operator can see which rule
    fired and on what values — no guesswork. *)
type reason = {
  rule_id : string;
      (** Short stable identifier (e.g. ["turn_fail_streak"]). *)
  evidence : string list;
      (** Concrete values that made the rule fire — already
          human-readable (e.g. ["turn_consecutive_failures=5"]). *)
}

(** Snapshot returned per keeper per poll. *)
type snapshot = {
  regime : regime;
  reason : reason;
      (** Empty evidence + [rule_id = "default_healthy"] when
          [regime = Healthy]. *)
  updated_at : float;
      (** Wall-clock when the snapshot was computed. *)
}

val derive :
  now:float ->
  Keeper_registry.registry_entry ->
  snapshot
(** [derive ~now entry] applies the regime rules in precedence order
    and returns the first match (or [Healthy] when none match).

    [now] is injected for determinism and testing — the deriver does
    not call [Unix.time] itself, matching the pure-projection contract
    of [Keeper_composite_observer]. Typical caller: the composite
    observer wrapper, which already has a wall-clock source. *)

val snapshot_to_json : snapshot -> Yojson.Safe.t
(** JSON projection for the dashboard telemetry response. Shape:

    {[
      {
        "regime": "thrashing",
        "rule_id": "turn_fail_streak",
        "evidence": [ "turn_consecutive_failures=5" ],
        "updated_at": 1234567890.12
      }
    ]}

    Stable — the dashboard API schema treats this as a forward-compat
    sub-object, and the TLA+ regime invariant reads [regime] as the
    enum value directly. *)

(** {1 Thresholds}

    Tunable constants exposed for tests. Defaults are conservative;
    revisit after 2-week empirical observation (per plan
    {e Track C}: empirical-before-design). *)

val turn_fail_streak_threshold : int
(** [turn_consecutive_failures >= N] triggers Thrashing.
    Default: 3. *)

val recent_restart_window_sec : float
(** Restarts within this window count as {e recent} for Crashing.
    Default: 300.0 (5 minutes). *)

val recent_restart_count_threshold : int
(** [restart_count] at or above this AND within the recent window
    triggers Crashing. Default: 2. *)

val tool_failure_count_threshold : int
(** A tool with [failures >= this] AND failure ratio exceeding
    {!tool_failure_ratio_threshold} contributes to Thrashing.
    Default: 3. *)

val tool_failure_ratio_threshold : float
(** Minimum [failures / count] ratio for a tool to count as saturated.
    Default: 0.7. *)
