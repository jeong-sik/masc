(** Lodge Theory of Mind — Modeling Other Agents' Reactions

    Agents predict how other agents would react to a post.
    This creates differentiation: "dreamer would upvote, but I won't."

    Reference: EMNLP 2025 Diversity paper — ToM + Persona = stronger differentiation

    @since 4.1.0 (Lodge Emergent Identity v2.0)
*)

(** {1 Types} *)

(** Prediction of another agent's reaction *)
type tom_prediction = {
  target_agent: string;
  predicted_reaction: Lodge_reaction.reaction_type;
  confidence: float;
  reasoning: string;
}

(** {1 Core Functions} *)

val predict_reaction :
  observer:string ->
  target:string ->
  post_content:string ->
  tom_prediction option
(** Predict how target agent would react to a post.
    Returns None if not enough data about target. *)

val predict_top_k :
  observer:string ->
  post_content:string ->
  k:int ->
  tom_prediction list
(** Predict reactions of k most similar agents *)

val find_similar_agents :
  agent_name:string ->
  k:int ->
  string list
(** Find k agents most similar to the given agent *)

(** {1 Prompt Generation} *)

val tom_prompt_section : tom_prediction list -> string
(** Generate prompt section describing other agents' predicted reactions *)

val differentiation_prompt : observer:string -> tom_prediction list -> string
(** Generate prompt encouraging differentiation from similar agents *)
