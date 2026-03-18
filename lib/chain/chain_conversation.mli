(** Chain Conversation - Conversational Mode Helpers

    Provides multi-turn conversation management with:
    - Token estimation and summarization
    - Model rotation across providers
    - Context window management
*)

(** {1 Types} *)

(** A single message in conversation history *)
type conv_message = {
  role: string;
  content: string;
  model: string;
  iteration: int;
}

(** Conversation context for maintaining history across iterations *)
type conversation_ctx = {
  mutable history: conv_message list;
  mutable current_model: string;
  mutable model_index: int;
  models: string list;
  token_threshold: int;
  window_size: int;
  mutable total_tokens: int;
  mutable summaries: string list;
}

(** {1 Token Estimation} *)

val estimate_tokens : string -> int
(** Estimate token count from string (rough: ~4 chars per token) *)

val estimate_conversation_tokens : conversation_ctx -> int
(** Estimate total tokens in conversation *)

(** {1 Context Management} *)

val make : ?models:string list -> ?token_threshold:int -> ?window_size:int -> unit -> conversation_ctx
(** Create conversation context with optional parameters *)

val add_message : conversation_ctx -> role:string -> content:string -> iteration:int -> model:string -> unit
(** Add a message to conversation history *)

val rotate_model : conversation_ctx -> unit
(** Rotate to next model in the list *)

val needs_summarization : conversation_ctx -> bool
(** Check if summarization is needed based on token threshold *)

val build_context_prompt : conversation_ctx -> string
(** Build context prompt from conversation history *)

(** {1 Summarization} *)

type exec_fn = model:string -> ?system:string -> prompt:string -> ?tools:Yojson.Safe.t -> ?thinking:bool -> unit -> (string, string) result
(** Type of LLM execution function for summarization *)

val summarize_history : exec_fn:exec_fn -> conversation_ctx -> string
(** Summarize history using LLM and compress context *)

val maybe_summarize_and_rotate : exec_fn:exec_fn -> conversation_ctx -> unit
(** Maybe summarize and rotate model if needed *)
