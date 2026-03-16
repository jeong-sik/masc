(** Llm_types — Shared type definitions, model registry, and parsing for the LLM client subsystem. *)

(** {1 Utility} *)

(** Read an integer from an environment variable, clamped to [min_v..max_v].
    Falls back to [default] if unset or unparseable. *)
val int_of_env_default : string -> default:int -> min_v:int -> max_v:int -> int

(** {1 Provider Types} *)

(** Supported LLM providers. *)
type provider =
  | Llama
  | Claude
  | OpenAI
  | Gemini
  | Glm_cloud
  | OpenRouter
  | Custom of string

(** Model specification — everything needed to call a specific model. *)
type model_spec = {
  provider : provider;
  model_id : string;           (** e.g. "glm-4.7-flash", "claude-opus-4-6" *)
  max_context : int;           (** Max context window in tokens *)
  api_url : string;            (** Base API URL *)
  api_key_env : string option; (** Env var name for API key *)
  cost_per_1k_input : float;   (** USD per 1K input tokens *)
  cost_per_1k_output : float;  (** USD per 1K output tokens *)
}

(** {1 Message Types} *)

(** Role in a conversation. *)
type role = System | User | Assistant | Tool

(** A single message in a conversation. *)
type message = {
  role : role;
  content : string;
  name : string option;       (** For tool messages: tool name *)
  tool_call_id : string option; (** For tool result messages *)
}

(** Tool/function definition for function calling. *)
type tool_def = {
  tool_name : string;
  tool_description : string;
  parameters : Yojson.Safe.t;  (** JSON Schema for parameters *)
}

(** A tool call requested by the model. *)
type tool_call = {
  call_id : string;
  call_name : string;
  call_arguments : string;     (** JSON string of arguments *)
}

(** Token usage from a completion.
    [cache_creation_input_tokens] and [cache_read_input_tokens] track
    Anthropic prompt caching metrics (0 for non-Anthropic providers). *)
type token_usage = {
  input_tokens : int;
  output_tokens : int;
  total_tokens : int;
  cache_creation_input_tokens : int;
  cache_read_input_tokens : int;
}

(** {1 Request/Response} *)

(** Completion request. *)
type completion_request = {
  model : model_spec;
  messages : message list;
  temperature : float;
  max_tokens : int;
  tools : tool_def list;
  response_format : [ `Text | `Json ];
}

(** Completion response. *)
type completion_response = {
  content : string;
  tool_calls : tool_call list;
  usage : token_usage;
  model_used : string;
  latency_ms : int;
}

(** {1 Request Normalization} *)

(** Clamp max_tokens for Llama provider requests. *)
val normalize_request : completion_request -> completion_request

(** {1 Provider Helpers} *)

(** String representation of provider. *)
val string_of_provider : provider -> string

(** String representation of role. *)
val string_of_role : role -> string

(** {1 Built-in Model Specs} *)

val llama_default : model_spec
val claude_opus : model_spec
val claude_sonnet : model_spec
val openai_default : model_spec
val glm_cloud : model_spec
val gemini_pro : model_spec

(** {1 Message Constructors} *)

(** Create a system message. *)
val system_msg : string -> message

(** Create a user message. *)
val user_msg : string -> message

(** Create an assistant message. *)
val assistant_msg : string -> message

(** Create a tool result message. *)
val tool_msg : name:string -> call_id:string -> string -> message

(** {1 Token Estimation} *)

(** Estimate token count for a message list (heuristic: ~4 chars per token). *)
val estimate_tokens : message list -> int

(** {1 Model Spec Parsing} *)

(** Parse model spec from string like "glm:glm-4.7",
    "claude:opus", "default", or "default:gemini-2.5-flash".
    Splits at the first ':' only, so model IDs may contain additional ':'. *)
val model_spec_of_string : string -> (model_spec, string) result

(** Parse model strings and keep only models that are callable in the current
    environment. Invalid specs and specs with missing API keys are skipped. *)
val available_model_specs_of_strings : string list -> model_spec list

(** Resolve the canonical default local model through the provider registry.
    Falls back to the first available execution model or GLM if parsing fails. *)
val default_local_model_spec : unit -> model_spec

(** Preferred model labels for execution defaults, resolved from explicit env
    overrides first, then available remote provider credentials, then any
    explicitly configured local model. *)
val default_execution_model_labels : unit -> string list

(** Preferred model labels for verifier defaults. *)
val default_verifier_model_labels : unit -> string list

(** Resolve the first callable execution default.
    Returns [Error _] instead of silently forcing a local model. *)
val default_execution_model_spec : unit -> (model_spec, string) result

(** Resolve the first callable verifier default.
    Returns [Error _] instead of silently forcing a local model. *)
val default_verifier_model_spec : unit -> (model_spec, string) result
