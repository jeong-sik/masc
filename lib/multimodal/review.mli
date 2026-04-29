(** Multimodal artifact review — Cycle 26 / Tier A10b.

    Anonymous evaluation result for an artifact. The review captures
    rubric scores across {!assessment_kind}s and derives a verdict
    against thresholds.

    Reviewer attribution (which persona issued the review) is
    intentionally NOT a field — it is supplied by the caller in the
    A10c bridge functor (`Crew_critique`). This keeps the multimodal
    library free of any [crew] dependency, preserving the layering:

      - lib/multimodal → shared_types, yojson  (this PR)
      - lib/crew       → shared_types, yojson  (existing)
      - lib/{crew_audit,crew_critique}  →  multimodal, crew  (A10c)

    A10b plan §2.2: ~150 LoC slice of the ~400 LoC A10 budget. *)

(* ── Score (bounded float in [0.0, 1.0]) ───────────────────────── *)

type score = private float

val score_of_float : float -> (score, string) result
(** [Error msg] if [f] is NaN, infinite, or outside [0.0, 1.0]. *)

val score_to_float : score -> float

val score_clip : float -> score
(** Clamp [f] to [0.0, 1.0]. NaN maps to [0.0]. *)

val score_zero : score

val score_one : score

(* ── Assessment dimensions ─────────────────────────────────────── *)

type assessment_kind =
  | Quality [@tla.symbol "quality"]
  | Safety [@tla.symbol "safety"]
  | Coherence [@tla.symbol "coherence"]
  | Coverage [@tla.symbol "coverage"]
[@@deriving tla]

val all_assessment_kinds : assessment_kind list

val assessment_kind_to_string : assessment_kind -> string

(* ── Rubric ────────────────────────────────────────────────────── *)

type rubric_score = {
  kind : assessment_kind;
  rubric : string;
  score : score;
  notes : string option;
}

val rubric_score_to_json : rubric_score -> Yojson.Safe.t

(* ── Verdict ───────────────────────────────────────────────────── *)

(** [Conditional] carries data, so a tag mirror is needed for
    ppx_tla derivation. *)
type verdict =
  | Pass
  | Fail
  | Conditional of { conditions : string list }

type verdict_tag =
  | Pass_tag [@tla.symbol "pass"]
  | Fail_tag [@tla.symbol "fail"]
  | Conditional_tag [@tla.symbol "conditional"]
[@@deriving tla]

val all_verdict_tags : verdict_tag list

val verdict_to_tag : verdict -> verdict_tag

val verdict_to_json : verdict -> Yojson.Safe.t

(* ── Review ────────────────────────────────────────────────────── *)

type review = {
  artifact_id : Shared_types.Artifact_id.t;
  rubric_scores : rubric_score list;
  overall : score;
  verdict : verdict;
  reviewed_at : float;
      (** Unix epoch seconds. We do not impose [Timestamp.t] here to
          keep the review module free of additional Shared_types
          surface. *)
}

val empty_review :
  artifact_id:Shared_types.Artifact_id.t ->
  reviewed_at:float ->
  review
(** Empty review — no rubric scores, [overall = score_zero],
    [verdict = Fail]. Add scores via {!add_rubric_score} and finalise
    with {!evaluate}. *)

val add_rubric_score : rubric_score -> review -> review

val with_rubric_scores : rubric_score list -> review -> review

(** {1 Evaluation}

    [evaluate ~pass_threshold ~conditional_threshold review] computes:

    - [overall] = mean of [rubric_scores] (or [score_zero] if empty)
    - if [overall ≥ pass_threshold]            → [Pass]
    - else if [overall ≥ conditional_threshold] → [Conditional]
      with each rubric below [pass_threshold] contributing its
      [rubric] field as a condition string.
    - else                                       → [Fail]

    Pre-condition: [pass_threshold ≥ conditional_threshold]. If
    violated the function still returns a well-formed review (the
    weaker of the two thresholds wins) but the verdict ordering
    becomes underspecified. *)
val evaluate :
  pass_threshold:score ->
  conditional_threshold:score ->
  review ->
  review

val review_to_json : review -> Yojson.Safe.t
