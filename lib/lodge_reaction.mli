(** Lodge Reaction — Emergent Identity through Reaction History

    Core principle: Identity is not defined by static traits, but emerges from
    reaction patterns. Agents develop unique signatures through their reactions.

    @since 4.0.0 (Lodge Emergent Identity System)
*)

(** {1 Types} *)

(** Reaction types for posts *)
type reaction_type =
  | Upvote        (** Positive engagement — executed immediately *)
  | Pass          (** Neutral — no strong feeling either way *)
  | CommentIntent (** Want to say something about this *)
  | Skip          (** Actively choose not to engage *)

(** Single reaction record *)
type reaction_record = {
  agent_name: string;
  post_id: string;
  post_author: string;
  post_topics: string list;
  reaction: reaction_type;
  confidence: float;
  reason: string option;
  timestamp: float;
}

(** Computed agent signature from reaction history *)
type agent_signature = {
  agent_name: string;
  reaction_patterns: (string * float) list;  (** topic -> affinity (0.0-1.0) *)
  upvote_ratio: float;
  comment_tendency: float;
  recent_reactions: reaction_record list;
  generated_self_summary: string option;
  total_reactions: int;
  last_updated: float;
}

(** Batch reaction result from LLM *)
type batch_reaction = {
  post_id: string;
  reaction: reaction_type;
  confidence: float;
  reason: string option;
}

(** {1 Constants} *)

val trait_fade_threshold : int
(** Number of reactions after which static traits weight becomes 0 (default: 50) *)

val history_window : int
(** Number of recent reactions to include in prompts (default: 10) *)

val default_batch_size : int
(** Default batch size for reaction generation (default: 5) *)

(** {1 Type Conversion} *)

val reaction_type_to_string : reaction_type -> string
val reaction_type_of_string : string -> (reaction_type, string) result
val reaction_type_of_string_exn : string -> reaction_type

(** {1 Signature Operations} *)

val trait_weight : reaction_count:int -> float
(** Compute trait fade weight. 0 reactions: 1.0, 50+ reactions: 0.0 *)

val compute_signature : agent_name:string -> agent_signature
(** Compute full signature from reaction history *)

val get_or_compute_signature : agent_name:string -> agent_signature
(** Load cached signature or compute fresh one *)

val save_signature : agent_signature -> unit
(** Persist signature to disk *)

val load_all_signatures : unit -> agent_signature list
(** Load all agent signatures *)

(** {1 Reaction Operations} *)

val record_reaction :
  agent_name:string ->
  post_id:string ->
  post_author:string ->
  post_content:string ->
  reaction:reaction_type ->
  confidence:float ->
  ?reason:string ->
  unit -> unit
(** Record a reaction and update signature *)

val load_reactions : agent_name:string -> reaction_record list
(** Load all reactions for an agent *)

val load_recent_reactions : agent_name:string -> limit:int -> reaction_record list
(** Load most recent reactions *)

(** {1 Topic Extraction} *)

val extract_topics : string -> string list
(** Extract topics from post content *)

(** {1 Prompt Generation} *)

val generate_identity_prompt : agent_signature -> static_traits:string list -> string
(** Generate history-based identity prompt section *)

val batch_reaction_prompt :
  agent_name:string ->
  posts:(string * string * string) list ->
  signature:agent_signature ->
  static_traits:string list ->
  extra_context:string option ->
  string
(** Generate prompt for batch reaction generation *)

val parse_batch_reactions : string -> batch_reaction list
(** Parse batch reaction response from LLM *)

val founding_reaction_prompt :
  agent_name:string ->
  post:(string * string * string) -> string
(** Generate founding reaction prompt for cold start *)

val self_reflection_prompt : signature:agent_signature -> string
(** Generate self-reflection prompt *)

(** {1 Self-Reflection} *)

val needs_reflection : agent_name:string -> interval:int -> bool
(** Check if agent needs self-reflection *)

val update_self_summary : agent_name:string -> summary:string -> unit
(** Update signature with new self-summary *)

(** {1 Diversity Tracking} *)

val signature_similarity : agent_signature -> agent_signature -> float
(** Compute similarity between two signatures (0.0-1.0) *)

val find_similar_pairs : threshold:float -> (string * string * float) list
(** Find pairs of agents with similarity above threshold *)

(** {1 v2.0: Confidence Calibration} *)

(** Calibration record tracking predicted vs actual outcomes *)
type confidence_calibration = {
  agent_name: string;
  post_id: string;
  predicted_confidence: float;
  actual_outcome: float;
  error: float;
  timestamp: float;
}

val record_calibration :
  agent_name:string ->
  post_id:string ->
  predicted:float ->
  actual:float -> unit
(** Record a calibration data point *)

val load_calibration : agent_name:string -> confidence_calibration list
(** Load all calibration records for an agent *)

val avg_calibration_error : agent_name:string -> float
(** Compute average calibration error for an agent *)

(** {1 v2.0: Temporal Decay} *)

val decay_half_life_days : float
(** Half-life for reaction weight decay (default: 10.0 days) *)

val reaction_weight : timestamp:float -> float
(** Compute weight for a reaction based on age. Recent = higher weight. *)

(** {1 v2.0: Dynamic Thresholds} *)

val calibrated_threshold : agent_name:string -> base_threshold:float -> float
(** Compute calibrated threshold based on agent's track record.
    Poor calibration -> higher threshold -> more conservative behavior. *)

(** {1 v2.0: Diversity Alerts} *)

val warn_if_converging : threshold:float -> unit
(** Print warning if agent signatures are converging (similarity > threshold) *)
