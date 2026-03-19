(** Context_manager — 3-tier memory with progressive compaction.

    Inspired by MemGPT virtual context management and G-Memory
    hierarchical graph memory.

    Tier 1: Working context — in-process, token-limited message list
    Tier 2: Session context — full history, checkpoints (JSONL)
    Tier 3: Semantic memory — cross-session via pgvector (external)

    @since 2.61.0 *)

(** {1 Working Context} *)

(** Working context: the message window sent to the LLM. *)
type working_context = {
  system_prompt : string;
  messages : Masc_model.message list;
  token_count : int;                (** Estimated tokens in window *)
  max_tokens : int;                 (** Model context limit *)
  importance_scores : (int * float) list;  (** msg_index → importance 0.0-1.0 *)
  oas_context : Agent_sdk.Context.t;  (** OAS scoped key-value store (Tier 1 bridge) *)
}

(** {1 Session Context} *)

(** A snapshot of working context at a point in time. *)
type checkpoint = {
  checkpoint_id : string;
  timestamp : float;
  generation : int;
  message_count : int;
  token_count : int;
  serialized : string;             (** JSON-encoded working context *)
}

(** Session context: full history + checkpoints for the current run. *)
type session_context = {
  session_id : string;
  session_dir : string;            (** Path to session JSONL files *)
  mutable full_history : Masc_model.message list;
  mutable checkpoints : checkpoint list;
}

(** {1 Compaction} *)

(** Compaction strategies, applied in order of increasing aggressiveness.
    Alias for {!Compaction_types.compaction_strategy} (shared SSOT). *)
type compaction_strategy = Compaction_types.compaction_strategy =
  | PruneToolOutputs   (** Remove verbose tool results > 500 chars, keep first/last 100 *)
  | MergeContiguous    (** Merge consecutive same-role messages *)
  | DropLowImportance  (** Remove messages with importance < 0.3 *)
  | SummarizeOld       (** LLM-summarize oldest 30% into 1 summary message *)

(** Result of compaction with optional history offload. *)
type compaction_result = {
  context : working_context;
  offloaded_path : string option;  (** Path to offloaded history markdown, if saved *)
}

(** {1 Context Ratio Thresholds} *)

(** Context window usage as a ratio 0.0-1.0. *)
val context_ratio : working_context -> float

(** True when context exceeds the given threshold. *)
val exceeds_threshold : working_context -> float -> bool

(** {1 Working Context Operations} *)

(** Create an empty working context for a given model. *)
val create : system_prompt:string -> max_tokens:int -> working_context

(** Replace the system prompt and recompute token_count.
    Useful when a keeper/perpetual goal or instructions change, while keeping messages. *)
val set_system_prompt : working_context -> system_prompt:string -> working_context

(** Append a message to working context, updating token count. *)
val append : working_context -> Masc_model.message -> working_context

(** Append multiple messages. *)
val append_many : working_context -> Masc_model.message list -> working_context

(** Score message importance (Stanford GAP formula adapted). *)
val score_importance : working_context -> working_context

(** {1 Compaction} *)

(** Prefix for goal-injection messages.
    Messages starting with this prefix receive sticky importance (>= 0.95)
    so they survive compaction.  Used by perpetual_loop to inject the goal
    as a user message rather than embedding it in the system prompt
    (preserves prompt-cache prefix). *)
val goal_prefix : string

(** Apply a pipeline of compaction strategies in order.
    Delegates to {!Context_compact_oas.compact}. *)
val compact : working_context -> compaction_strategy list -> working_context

(** Format a single message as human-readable text: "role: content". *)
val format_message_readable : Masc_model.message -> string

(** Offload messages to a markdown file in [{session_dir}/offloaded/{compaction_count}.md].
    Returns [Some path] on success, [None] on failure (fail-safe, never raises). *)
val offload_messages :
  session_dir:string -> compaction_count:int ->
  Masc_model.message list -> string option

(** Apply compaction with history offload.
    Before compaction, saves the full pre-compaction messages to a markdown file.
    The summary message is annotated with the offload path.
    If offload fails, compaction proceeds normally. *)
val compact_with_offload :
  session_ctx:session_context -> compaction_count:int ->
  working_context -> compaction_strategy list -> compaction_result

(** Sync working context stats (message_count, token_count, context_ratio)
    into the OAS Context scoped keys. Called automatically by [compact]. *)
val sync_oas_context : working_context -> working_context

(** Extract [STATE] ... [/STATE] blocks from free-form text.
    Returns the block bodies in appearance order. *)
val extract_state_blocks : string -> string list

(** {1 Serialization} *)

(** Serialize working context to JSON string. *)
val serialize_context : working_context -> string

(** Deserialize working context from JSON string. *)
val deserialize_context : string -> max_tokens:int -> working_context

(** {1 Checkpointing} *)

(** Create a checkpoint from current working context. *)
val create_checkpoint : working_context -> generation:int -> checkpoint

(** Restore working context from a checkpoint. *)
val restore_checkpoint : checkpoint -> max_tokens:int -> working_context

(** {1 Session Persistence} *)

(** Create a new session context in the given directory. *)
val create_session : session_id:string -> base_dir:string -> session_context

(** Persist a message to session history (append to JSONL). *)
val persist_message : session_context -> Masc_model.message -> unit

(** Save checkpoint to session directory. *)
val save_checkpoint : session_context -> checkpoint -> unit

(** Load latest checkpoint from session directory. *)
val load_latest_checkpoint : session_context -> checkpoint option
