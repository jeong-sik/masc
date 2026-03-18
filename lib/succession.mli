(** Succession — Cross-model relay engine for infinite agent lifecycle.

    Handles context transfer between agents, potentially running
    different LLM models.  Extends the mitosis/relay pattern with:
    - Structured DNA (goal, progress, decisions, metrics)
    - Cross-model normalization (Claude ↔ local runtimes such as llama:<model>/ollama:<model> ↔ GLM)
    - Generation tracking across the succession chain

    @since 2.61.0 *)

(** {1 Types} *)

(** Metrics accumulated across the succession chain. *)
type succession_metrics = {
  total_turns : int;
  total_tokens_used : int;
  total_cost_usd : float;
  tasks_completed : int;
  errors_encountered : int;
  elapsed_seconds : float;
}

(** DNA payload — compressed state for the successor agent. *)
type succession_dna = {
  generation : int;              (** How many handoffs from origin *)
  trace_id : string;             (** Unique ID for the entire chain *)
  goal : string;                 (** Current high-level goal *)
  progress_summary : string;     (** What has been accomplished *)
  compressed_context : string;   (** Compacted working context *)
  pending_actions : string list;
  key_decisions : string list;
  memory_refs : string list;     (** pgvector IDs for semantic recall *)
  warnings : string list;
  metrics : succession_metrics;
}

(** Successor specification — what model the next agent uses. *)
type successor_spec = {
  model : Llm.model_spec;
  inherit_tools : bool;          (** Pass tool definitions to successor *)
  context_budget : float;        (** 0.0-1.0: how much context to transfer *)
}

(** {1 DNA Operations} *)

(** Extract DNA from current agent state.
    Compresses working context + session metadata into a transferable payload. *)
val extract_dna :
  working_ctx:Context_manager.working_context ->
  session_ctx:Context_manager.session_context ->
  goal:string ->
  generation:int ->
  trace_id:string ->
  metrics:succession_metrics ->
  succession_dna

(** Build initial working context for successor from DNA.
    Hydrates the compressed context and injects DNA as system context. *)
val hydrate :
  succession_dna ->
  successor_spec ->
  Context_manager.working_context

(** {1 Cross-Model Normalization} *)

(** Normalize message list for a target model.
    Handles provider-specific quirks (system message placement,
    tool format differences, token limit trimming). *)
val normalize_for_model :
  Llm.message list ->
  Llm.model_spec ->
  Llm.message list

(** {1 Serialization} *)

(** DNA to JSON for persistence/transfer. *)
val dna_to_json : succession_dna -> Yojson.Safe.t

(** DNA from JSON. *)
val dna_of_json : Yojson.Safe.t -> (succession_dna, string) result

(** Empty metrics. *)
val empty_metrics : succession_metrics

(** Merge two metrics (for accumulation across generations). *)
val merge_metrics : succession_metrics -> succession_metrics -> succession_metrics
