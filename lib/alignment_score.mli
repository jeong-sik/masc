(** Alignment Score backend - Master Report Dim03 P2 (RFC-0035 PR-6).

    Pure OCaml implementation of the 10-metric Alignment Score (AS)
    formula from Master Report section 3.3.  Given raw {!metrics} measured by
    the caller (host: keeper / planner / static analyser), produces:

    - 10 normalised values in {!normalized}, each in the closed
      interval [0.0, 100.0];
    - a single weighted score in {!result.score} (0-100, integer);
    - a {!grade} from {!A} to {!F};
    - a list of {!warning} flags raised when raw metrics cross Master
      Report thresholds.

    The module owns *only* the formula. Measurement of [trc] / [cov] /
    [cmp] / etc. is the caller's responsibility - different consumers
    will tap different sources (Plan <-> Code symbol map, AST diff,
    AI-classifier confidence, etc.).

    The module is intentionally pure: no I/O, no Eio, no global
    state. Custom JSON codec for {!result_to_yojson} so the dashboard
    can consume the report without an additional schema layer. The
    wire format uses camelCase keys.

    @stability Evolving
    @since 0.19.16 *)

(** Raw input metrics.

    Each field's range and ideal value follows Master Report section 3.2:

    - [trc]  : 0..1, ideal 1.0 - Plan <-> code traceability ratio
    - [cov]  : 0..1, ideal 1.0 - feature coverage ratio
    - [cmp]  : >0,   ideal 1.0 - actual_cc / expected_cc
    - [crn]  : >0,   ideal 1.0 - actual_changes / expected_changes
    - [dbt]  : 0..infinity, ideal 0 - tech-debt ratio
    - [tmp]  : >0,   ideal 1.0 - actual_time / expected_time
    - [dir]  : -1..1, ideal 1.0 - direction-vector dot product
    - [coh]  : 0..1, ideal 1.0 - module cohesion ratio
    - [bnd]  : 0..infinity, ideal 0 - boundary-violation count (normalised
      by caller; e.g. violations / max_expected)
    - [cnf]  : 0..1, ideal 1.0 - AI confidence

    The normalisation in {!normalize} clamps each value to [0.0,
    100.0] regardless of out-of-range input. *)
type metrics = {
  trc : float;
  cov : float;
  cmp : float;
  crn : float;
  dbt : float;
  tmp : float;
  dir : float;
  coh : float;
  bnd : float;
  cnf : float;
}

(** Component weights used in the final score formula. *)
type weights = {
  trc : float;
  cov : float;
  cmp : float;
  crn : float;
  dbt : float;
  tmp : float;
  dir : float;
  coh : float;
  bnd : float;
  cnf : float;
}

(** Master Report section 3.3 default weights (sum = 1.0). *)
val default_weights : weights

(** Sum of every component in [w]. Useful for tests that assert the
    weights still sum to 1.0 after a custom override. *)
val sum_weights : weights -> float

(** Normalised metric values, each in the closed interval [0.0,
    100.0].  Values outside the input ranges are clamped before
    multiplication. *)
type normalized = {
  trc : float;
  cov : float;
  cmp : float;
  crn : float;
  dbt : float;
  tmp : float;
  dir : float;
  coh : float;
  bnd : float;
  cnf : float;
}

(** 5-step grade scale, from highest to lowest. *)
type grade =
  | A
  | B
  | C
  | D
  | F

val grade_to_string : grade -> string

(** [grade_of_score s] applies Master Report section 3.3 thresholds:
    [s >= 90 -> A], [>=75 -> B], [>=60 -> C], [>=40 -> D], else [F]. *)
val grade_of_score : float -> grade

(** Warning flags surfaced by {!calculate} when individual raw
    metrics cross Master Report thresholds. *)
type warning =
  | Low_traceability   (** trc < 0.5 *)
  | Low_coverage       (** cov < 0.5 *)
  | High_debt          (** dbt > 0.5 *)
  | Behind_schedule    (** tmp > 1.5 (very slow vs plan) *)
  | Wrong_direction    (** dir < 0 *)

val warning_to_string : warning -> string

(** Output of {!calculate}. *)
type result = {
  score : int;
  grade : grade;
  warnings : warning list;
  normalized : normalized;
}

(** Apply Master Report section 3.3 normalisation rules to raw metrics. *)
val normalize : metrics -> normalized

(** Compute the weighted alignment score, grade and warnings.  The final
    score is rounded to an integer before assigning the grade, so the
    displayed score and grade stay consistent.  [weights] defaults to
    {!default_weights}. *)
val calculate : ?weights:weights -> metrics -> result

(** {1 JSON codec}

    Wire format uses stable keys: [score], [grade] (uppercase
    string), [warnings] (array of lowercase strings), [normalized]
    (object keyed by metric code in lowercase). *)

val result_to_yojson : result -> Yojson.Safe.t
