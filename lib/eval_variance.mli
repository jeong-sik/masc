(** Eval_variance — run-variance measurement spine (task-628 / roadmap M1).

    Quantifies run-to-run variance of eval metrics so a reported delta is
    actionable only when its confidence interval excludes 0. Motivated by
    the finding that temp=0 does NOT make an agent turn deterministic, so a
    single-run point estimate is noise (Bjarnason/Silva/Monperrus,
    arXiv 2602.07150, 2026-03; pp figures unverified — used as motivation).

    Pure stdlib: this module deliberately has NO dependency on the rest of
    [masc_mcp] (no cascade / runtime / OAS). It models the statistics; the
    N-run execution driver and the wiring into {!Eval_harness} reporting and
    {!Eval_gate} thresholds are separate (and currently blocked on the
    cascade->Runtime migration leaving the monolith green). Keeping the core
    standalone lets it be verified in isolation today.

    Design: illegal states are unrepresentable — a band cannot be built from
    fewer than 2 score samples (variance undefined) or 0 trials, so the
    constructors return [option]; the comparison verdict and the gate result
    are closed sums, not strings. *)

type variance_band = {
  mean : float;       (** point estimate (mean score, or proportion) *)
  std : float;        (** sample standard deviation (n-1 denominator) *)
  n : int;            (** number of samples / trials *)
  stderr : float;     (** standard error of the mean = std / sqrt n *)
  ci_low : float;     (** lower bound of the [confidence] interval *)
  ci_high : float;    (** upper bound of the [confidence] interval *)
  ci_width : float;   (** ci_high - ci_low *)
  confidence : float; (** e.g. 0.95 *)
}

val z_for_confidence : float -> float
(** Two-sided normal critical value z for a confidence level in (0,1),
    via Acklam's inverse-normal-CDF approximation. [z_for_confidence 0.95]
    is ~1.95996. Clamps inputs to the open interval (0,1). *)

val band_of_scores : ?confidence:float -> float list -> variance_band option
(** Normal-approximation CI on the mean of continuous scores.
    [confidence] defaults to 0.95 and is clamped to (0,1).
    Returns [None] for fewer than 2 samples (sample variance undefined).
    NOTE: the normal approximation is slightly anti-conservative for very
    small n vs Student-t; the gate's [min_runs] is the guard. *)

val band_of_proportion :
  ?confidence:float -> trials:int -> successes:int -> unit -> variance_band option
(** Wilson score interval for a pass-rate proportion (correct near 0/1 where
    the normal approximation is not). [mean] = successes / trials.
    Returns [None] if [trials] < 1 or [successes] not in [0, trials].
    The trailing [unit] lets the optional [?confidence] be erased (the
    required arguments are all labelled). *)

type verdict =
  | Improvement   (** difference CI lies entirely above 0 *)
  | Regression    (** difference CI lies entirely below 0 *)
  | Inconclusive  (** difference CI includes 0 — within run-to-run noise *)

type difference = {
  delta : float;      (** candidate.mean - baseline.mean *)
  se : float;         (** pooled standard error sqrt(se_base^2 + se_cand^2) *)
  ci_low : float;     (** lower bound of the CI of the difference *)
  ci_high : float;    (** upper bound of the CI of the difference *)
  confidence : float;
  verdict : verdict;  (** Improvement/Regression iff the CI excludes 0 *)
}
(** The full result of a two-sample difference test — the inspectable delta
    AND its confidence interval, not just the [verdict]. This is what the
    A/B harness (roadmap M2: injected-vs-not) and the evolving-brain
    visibility surfaces render ("delta = +0.07 [0.02, 0.12]"); [compare]
    keeps only the verdict. *)

val compare :
  ?confidence:float ->
  baseline:variance_band ->
  candidate:variance_band ->
  unit ->
  verdict
(** Two independent-sample difference test on the means. The CI of
    (candidate.mean - baseline.mean) uses the pooled standard error
    sqrt(se_base^2 + se_cand^2). The harness contract: a regression or
    improvement is declared ONLY when that difference CI excludes 0;
    otherwise the delta is [Inconclusive] (do not act on it). *)

val difference :
  ?confidence:float ->
  baseline:variance_band ->
  candidate:variance_band ->
  unit ->
  difference
(** The inspectable difference (delta + its CI + verdict). [compare] is
    exactly [(difference ...).verdict] — this is the single source of the
    math. The CI of (candidate.mean - baseline.mean) uses the pooled
    standard error; a verdict of Improvement/Regression is returned ONLY
    when that CI excludes 0. *)

val verdict_to_string : verdict -> string

val difference_to_json : difference -> Yojson.Safe.t
(** Serialize a difference (delta, CI bounds, verdict) for the eval JSONL /
    dashboard A/B and run-comparison surfaces. *)

type gate = {
  min_runs : int;       (** minimum N for a band to be trusted *)
  max_ci_width : float; (** maximum acceptable CI width for a band *)
}

val default_gate : gate
(** [{ min_runs = 5; max_ci_width = 0.20 }] — the roadmap M1 starting policy
    (N>=5; CI no wider than 0.20 on a 0..1 score). Tune per fixture. *)

type gate_result =
  | Gate_ok
  | Too_few_runs of { got : int; need : int }
  | Ci_too_wide of { got : float; max : float }

val check_gate : gate -> variance_band -> gate_result
(** A band is only trustworthy with at least [min_runs] samples and a CI no
    wider than [max_ci_width]. Returns the first violation, or [Gate_ok]. *)

val variance_band_to_json : variance_band -> Yojson.Safe.t
(** Serialize a band for the eval JSONL / dashboard surfaces. *)
