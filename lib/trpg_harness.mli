(** trpg_harness.mli — TRPG Keeper Evaluation Harness.

    2-Tier LLM-as-judge system:
    - Tier 1: Structural gate (cheap model, ~50 tokens)
    - Tier 2: Quality evaluation (capable model, ~200 tokens)

    3 scoring dimensions:
    - Character fidelity (weight 0.4)
    - Human likeness (weight 0.3)
    - Narrative consistency (weight 0.3)

    @since 2.70.0 *)

type dimension = Character_fidelity | Human_likeness | Narrative_consistency

type dimension_score = {
  dimension : dimension;
  score : float;       (** 1-5 scale *)
  reason : string;
}

type tier1_result = Pass | Fail of string

type evaluation_result = {
  tier1 : tier1_result;
  scores : dimension_score list;    (** Empty if tier1 fails *)
  weighted_total : float;           (** 0.0 if tier1 fails *)
  raw_response : string;
  evaluated_at : string;            (** ISO8601 timestamp *)
}

(** Tier 1 structural gate. Checks: valid JSON action, non-empty narrative,
    not out-of-character gibberish. Returns Pass or Fail with reason.
    Budget: max 50 tokens, temperature 0.0 *)
val tier1_check : model:Llm.model_spec -> actor_name:string ->
  actor_persona:string -> response_text:string -> tier1_result

(** Tier 2 quality evaluation. Scores across 3 dimensions.
    Budget: max 200 tokens, temperature 0.0.
    Only called if tier1 passes. *)
val tier2_evaluate : model:Llm.model_spec -> actor_name:string ->
  actor_persona:string -> actor_traits:string list -> scene_context:string ->
  response_text:string -> dimension_score list

(** Full evaluation pipeline: tier1 -> tier2 (if pass) -> weighted score.
    tier1_model: cheap model (e.g., ollama:LFM2.5-1.2B-Instruct)
    tier2_model: capable model (e.g., glm:glm-4.7-flash) *)
val evaluate : tier1_model:Llm.model_spec -> tier2_model:Llm.model_spec ->
  actor_name:string -> actor_persona:string -> actor_traits:string list ->
  scene_context:string -> response_text:string -> evaluation_result

(** Convert evaluation_result to JSON for event storage. *)
val result_to_yojson : evaluation_result -> Yojson.Safe.t

(** String representation of dimension. *)
val string_of_dimension : dimension -> string

(** {2 Exposed for testing} *)

(** Parse tier1 LLM response text into Pass/Fail. *)
val parse_tier1 : string -> tier1_result

(** Parse tier2 LLM response text into dimension scores.
    Returns default score (3.0) for any dimension not found. *)
val parse_tier2 : string -> dimension_score list

(** Compute weighted total from dimension scores, normalized to 0.0-1.0. *)
val compute_weighted_total : dimension_score list -> float
