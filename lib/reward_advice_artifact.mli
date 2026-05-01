(** Reward_advice_artifact — Structured advisory artifacts from verifiers and benchmarks.

    Bridges verification verdicts and benchmark scores to the reward system
    with evidence-backed advisory hints.

    The advisory pattern means callers decide whether to apply the recommended
    [reward_multiplier]; the artifact itself is a proposal, not a command.

    @since Task-044 — Advisory Reward Advice Artifacts *)

(** {1 Types} *)

(** Source module that produced this artifact. *)
type advice_source =
  | Post_verifier   (** Heuristic 3-dimension content check. *)
  | Benchmark       (** Tool-call quality benchmark scoring. *)
  | Task_verifier   (** OAS/LLM task action verifier. *)

(** A structured advisory hint from a verifier or benchmark to the reward system. *)
type reward_advice_artifact = {
  source : advice_source;
  agent_name : string;
  task_id : string option;
  verdict : string;            (** "pass", "warn", or "fail" *)
  reward_multiplier : float;   (** Suggested multiplier [0.0, 2.0]; 1.0 = neutral. *)
  advisory_message : string;   (** Human/LLM-readable guidance for the reward system. *)
  evidence_refs : string list; (** References to supporting evidence (tool call ids, etc.). *)
  confidence : float;          (** Confidence in the advice [0.0, 1.0]. *)
  timestamp : float;           (** Unix timestamp of artifact creation. *)
}

val advice_source_to_string : advice_source -> string
(** Render a source as a lowercase string: "post_verifier", "benchmark", "task_verifier". *)

val advice_source_of_string : string -> advice_source option
(** Parse a source from string.  Returns [None] for unknown values. *)

val multiplier_of_verdict : string -> float
(** Derive a suggested reward multiplier from a verdict string.
    "pass" → 1.0, "warn" → 0.8, "fail" → 0.4, other → 1.0. *)

(** {1 Serialization} *)

val to_yojson : reward_advice_artifact -> Yojson.Safe.t
(** Serialize to JSON. *)

val of_yojson : Yojson.Safe.t -> (reward_advice_artifact, string) result
(** Deserialize from JSON.  Returns [Error] when required fields are missing
    or the source string is unrecognized. *)

(** {1 Factory functions} *)

val of_post_verifier_verdict :
  agent_name:string ->
  ?task_id:string ->
  verdict:string ->
  advisory_message:string ->
  unit ->
  reward_advice_artifact
(** Build an artifact from post-verifier verdict components.
    Called by {!Post_verifier.to_reward_advice}; avoids a circular dependency
    between [Post_verifier] and [Reward_advice_artifact].
    - "pass" → multiplier 1.0, confidence 1.0
    - "warn" → multiplier 0.8, confidence 0.9
    - "fail" → multiplier 0.4, confidence 1.0 *)

val of_benchmark_case_score :
  agent_name:string ->
  ?task_id:string ->
  Tool_call_quality_benchmark_types.case_score ->
  reward_advice_artifact
(** Build an artifact from a {!Tool_call_quality_benchmark_types.case_score}.
    Composite score >= 0.8 → pass (multiplier 1.1 bonus);
    >= 0.5 → warn (multiplier 0.9);
    <  0.5 → fail (multiplier 0.5). *)
