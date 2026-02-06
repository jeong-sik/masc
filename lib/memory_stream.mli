(** Memory Stream — Scored retrieval memory for Generative Agents.

    Based on Stanford Generative Agents (Park et al. 2023):
    score = α·recency + β·importance + γ·relevance

    Phase 1: JSONL persistence, keyword-based relevance.
    Phase 2+: Qdrant embedding-based relevance.

    @since 4.0.0 *)

(** {1 Types} *)

type memory_type =
  | Observation of string   (** Seen on the board *)
  | Action of string        (** Agent's own action *)
  | Reflection of string    (** Derived from reflection *)
  | Plan of string          (** From daily planning *)

type memory_entry = {
  id: string;
  agent_name: string;
  content: string;
  timestamp: float;
  importance: int;          (** 1-10, LLM-judged *)
  entry_type: memory_type;
}

(** {1 Scoring Weights} *)

type scoring_weights = {
  alpha: float;  (** recency weight, default 1.0 *)
  beta: float;   (** importance weight, default 1.0 *)
  gamma: float;  (** relevance weight, default 1.0 *)
}

val default_weights : scoring_weights

(** {1 Core Operations} *)

(** Load all entries from the agent's memory stream. *)
val load_all_entries : agent_name:string -> memory_entry list

(** Rewrite all entries atomically (used by memory GC). *)
val rewrite_entries : agent_name:string -> memory_entry list -> unit

(** Add a new memory entry to the stream.
    [importance] is 1-10 (higher = more important).
    Automatically rotates file if > max_entries. *)
val add_memory :
  agent_name:string ->
  content:string ->
  importance:int ->
  memory_type ->
  unit

(** Retrieve top-N memories by scored retrieval.
    score = α·recency + β·importance + γ·relevance
    where relevance is keyword overlap with [query]. *)
val retrieve :
  agent_name:string ->
  query:string ->
  limit:int ->
  memory_entry list

(** Get recent memories within [hours] hours. *)
val recent :
  agent_name:string ->
  hours:float ->
  memory_entry list

(** Sum of importance scores since [since] timestamp.
    Used to trigger reflection (threshold = 100). *)
val importance_sum_since :
  agent_name:string ->
  since:float ->
  int

(** {1 Formatting} *)

(** Format memories as a context string for LLM prompts. *)
val format_memories : memory_entry list -> string

(** {1 Maintenance} *)

(** Maximum entries per agent before rotation. *)
val max_entries : int

(** Rotate: archive old entries when stream exceeds max_entries. *)
val rotate_if_needed : agent_name:string -> unit
