(** OpenAI-compatible request serialization.

    @since 0.92.0 extracted from Backend_openai

    @stability Internal
    @since 0.93.1 *)

(** [system_prompt_with_thinking_token ~thinking_requested ~config ~caps] returns
    [config.system_prompt]
    with the chat-template thinking token prepended when the resolved [caps]
    declare a [Chat_template_token] and thinking is requested, else the prompt
    unchanged. SSOT for both the Ollama-native and OpenAI-compat request builders
    so the same catalog row cannot be handled asymmetrically (oas#2483: the
    OpenAI-compat wire used to drop the token silently, producing blank-content
    200s / empty-turn storms). *)
val system_prompt_with_thinking_token
  :  thinking_requested:bool
  -> config:Provider_config.t
  -> caps:Capabilities.capabilities
  -> string option

(** [chat_template_thinking_active ~thinking_requested ~caps] is [true] when a
    [Chat_template_token] is declared and thinking is requested — i.e. the token
    was injected into the system turn. Ollama uses it to omit the native [think]
    field for these rows. *)
val chat_template_thinking_active
  :  thinking_requested:bool
  -> caps:Capabilities.capabilities
  -> bool

(** Resolve the explicit request flag, using [default] only when
    [config.enable_thinking] is absent.  The caller owns the backend-specific
    default; this shared serializer never reads provider environment variables. *)
val thinking_requested : default:bool -> Provider_config.t -> bool

val tool_calls_to_openai_json : Types.content_block list -> Yojson.Safe.t list
val openai_content_parts_of_blocks : Types.content_block list -> Yojson.Safe.t list
val openai_messages_of_message : Types.message -> Yojson.Safe.t list

type history_projection =
  { messages : Yojson.Safe.t list
  ; reasoning_replay_drops : Reasoning_history_projection.reasoning_replay_drop list
  ; removed_empty_assistant_indices : int list
  }
[@@deriving show]

val dialect_history_projection
  :  ?assistant_tool_content_format:Capability_vocab.assistant_tool_content_format
  -> replay_capability:Reasoning_dialect.replay_capability
  -> Reasoning_dialect.t
  -> Types.message list
  -> (history_projection, Reasoning_history_projection.error) result

val dialect_messages_of_history
  :  ?assistant_tool_content_format:Capability_vocab.assistant_tool_content_format
  -> replay_capability:Reasoning_dialect.replay_capability
  -> Reasoning_dialect.t
  -> Types.message list
  -> (Yojson.Safe.t list, Reasoning_history_projection.error) result

(** Serialize a whole Ollama native history through an immutable,
    occurrence-scoped ToolUse-to-ToolResult projection. Ollama tool results
    carry [tool_name], not the OpenAI-compatible [tool_call_id]. Missing or
    ambiguous correlation is returned explicitly so the HTTP serialization
    boundary can reject it. *)
val ollama_messages_of_history
  :  modality_priority:Modality.priority
  -> supports_image_input:bool
  -> supports_document_input:bool
  -> Types.message list
  -> (Yojson.Safe.t list, string) result

val tool_choice_to_openai_json : Types.tool_choice -> Yojson.Safe.t

(** [parallel_tool_calls_fields ~disable_parallel ~tools_present] returns the
    OpenAI-compatible [parallel_tool_calls] body field: [("parallel_tool_calls",
    `Bool false)] in a singleton list when parallel calls are disabled and tools
    are present, else the empty list. Shared by the low-level request builder and
    the agent-state-aware API layer so the wire shape is defined once. *)
val parallel_tool_calls_fields
  :  disable_parallel:bool
  -> tools_present:bool
  -> (string * Yojson.Safe.t) list

(** Validated current tool definition shared by provider-specific wire
    serializers. Exactly one of [input_schema] or object-valued [parameters]
    supplies [parameters]. *)
type tool_definition =
  { name : string
  ; description : string
  ; parameters : Yojson.Safe.t
  ; strict : bool option
  }

val tool_definition_of_json : Yojson.Safe.t -> tool_definition
val tool_definition_fields : tool_definition -> (string * Yojson.Safe.t) list

(** Lower a validated current tool object to the OpenAI-compatible function
    shape. *)
val build_openai_tool_json : Yojson.Safe.t -> Yojson.Safe.t
