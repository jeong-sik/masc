(** Confidence — composite confidence scoring with factor decomposition.

    Cycle 23 / Tier B7 — first cut.

    {1 What this module is}

    Confidence is not a single scalar; it is a composite metric
    derived from {b artifact quality}, {b verification depth},
    {b degradation penalty}, and {b consensus agreement}. The
    autonomous engine and CREW deliberation produce confidence
    factors during execution; this module combines them into a
    final score, compares against a policy threshold, and
    surfaces an actionable recommendation when the score is low.

    {1 Scope of this PR}

    - {!factor} variant: four contribution kinds.
    - {!report} record: composite score (via
      {!Shared_types.Confidence.t}), the factor decomposition,
      the threshold, the [below_threshold] flag, and an optional
      {!recommendation}.
    - {!evaluate}: geometric mean of factor scores combined with
      the multiplicative {!Degradation} penalty (when present);
      compared to the threshold to populate the report.
    - {!is_acceptable}: predicate combining threshold + recommendation.
    - {!worst_factor}: identify the single factor that most
      reduced the composite score — useful for targeted recovery.

    {1 Deferred to follow-up Tiers}

    - [factor_of_verifications]: bridge to OAS
      [Verified_output.verification_result]. Requires importing the
      OAS verification surface, deferred to keep this PR's
      dependency footprint bounded.
    - [apply_policy]: bridge to OAS [Policy.t]. Same deferral.
    - The {!recommendation.Degrade} variant carries a [target_level]
      [int]; Tier A11 introduces [Resilience.Degradation.level] which
      will retype this field with no constructor renaming. *)

(** {1 Factors} *)

(** A single factor contributing to the final confidence score. *)
type factor =
  | Artifact of { producer : string; raw_score : float }
      (** Confidence contributed by the artifact producer itself.
          [raw_score] is in [\[0.0, 1.0\]]; values outside that
          range are clamped by {!evaluate}. *)
  | Verification of {
      verifier : string;
      score : float;
      evidence : string;
    }
      (** Confidence contributed by an independent verifier
          (e.g. CREW peer review or [Verified_output] cross-check). *)
  | Degradation of { level : int; penalty : float }
      (** Multiplicative penalty applied because the system is
          running at a reduced level (L2..L4). [penalty] in
          [\[0.0, 1.0\]]; lower means stronger penalty. *)
  | Consensus of {
      agree_count : int;
      total_count : int;
      method_ : string;
    }
      (** Confidence derived from multi-persona consensus
          (e.g. 5 of 6 CREW personas agree). *)

(** {1 Recommendations} *)

(** Recommended action when confidence falls below the threshold. *)
type recommendation =
  | NoAction
  | RequestVerification of { who : string; why : string }
      (** Ask an independent verifier to re-check the primary artifact. *)
  | Degrade of { target_level : int; why : string }
      (** Drop to a lower degradation level. [target_level] is an
          [int] for now; Tier A11 introduces a typed level. *)
  | Handoff of { reason : string }
      (** Escalate to a human operator; autonomy cannot proceed safely. *)

(** {1 Reports} *)

(** A complete confidence report with actionable recommendation. *)
type report = {
  final : Shared_types.Confidence.t;
      (** The composite confidence score, clamped via
          {!Shared_types.Confidence.make}. *)
  factors : factor list;
      (** Decomposition of how [final] was derived. *)
  threshold : float;
      (** The policy threshold that [final] was compared against. *)
  below_threshold : bool;
      (** [true] iff [Shared_types.Confidence.to_float final
          < threshold]. *)
  recommendation : recommendation option;
      (** Recommendation populated when [below_threshold = true]. *)
}

(** {1 Construction} *)

val evaluate : factors:factor list -> threshold:float -> report
(** [evaluate ~factors ~threshold] computes [final] as the
    geometric mean of {b non-Degradation} factor scores, then
    multiplies by every {!Degradation} factor's [penalty]. The
    result is clamped to [\[0.0, 1.0\]] via
    {!Shared_types.Confidence.make}.

    When [factors = []] (or only contains Degradation entries with
    no other factor to weight), [final] is taken to be [0.0] —
    the absence of any positive evidence cannot ground confidence.

    The recommendation is selected as follows:
    - [final >= threshold]                 → [None]
    - [final < threshold] + Verification only is weak →
      [Some (RequestVerification { ... })]
    - [final < threshold] + Degradation present →
      [Some (Degrade { target_level = max_level + 1; ... })]
    - [final << threshold] (≤ 50% of threshold)        →
      [Some (Handoff { reason = ... })]
    - otherwise                            → [Some NoAction]
      (caller may override). *)

(** {1 Queries} *)

val is_acceptable : report -> bool
(** [true] iff [report.below_threshold = false] AND [recommendation
    = None]. Either flag tripping yields [false]. *)

val worst_factor : report -> factor option
(** Return the factor whose individual contribution most reduced
    the composite score, or [None] when [factors = []]. The
    "contribution" of each factor is its raw score (or its penalty
    for [Degradation]); the worst is the one with the lowest such
    value. Useful for targeted recovery. *)

(** {1 Convenience constructors} *)

val artifact : producer:string -> score:float -> factor
val verification : verifier:string -> score:float -> evidence:string -> factor
val degradation : level:int -> penalty:float -> factor
val consensus :
  agree_count:int -> total_count:int -> method_:string -> factor
