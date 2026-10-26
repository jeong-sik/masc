(** Shared leaf vocabulary for declarative capability fields. *)

type thinking_control_format =
  | No_thinking_control
  | Thinking_object
  | Thinking_object_adaptive
  | Thinking_object_only
  | Chat_template_kwargs
  | Chat_template_token of string
  | Ollama_think
  | Reasoning_effort
  | Reasoning_effort_default_on
  (** Categorical depth with reasoning enabled when effort is omitted.
      Explicit enable is already satisfied; disable still requires an accepted [none]. *)

type preserve_thinking_control_format =
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Always_preserved_thinking
  | Thinking_object_clear_thinking

(** What the request wire does about reasoning when the request carries no
    thinking control at all. [Provider_default_reasoning] is the ordinary case:
    absence leaves the decision to the provider's own default and masc claims
    nothing about it. [Provider_enables_reasoning] is the endpoint that turns
    reasoning on by itself when no control is present, so on that wire an
    absent control is not "reasoning off" -- it is "reasoning on, undeclared".

    No catalog string maps to this: which wire enables reasoning on its own is
    a property of the endpoint, measured once and declared on the provider
    preset, not something an individual model row restates. *)
type uncontrolled_reasoning =
  | Provider_default_reasoning
  | Provider_enables_reasoning

type reasoning_replay_override =
  | Default_reasoning_replay
  | Force_no_replay
  | Force_drop_without_tool_preserve_with_tool
  | Force_latest_user_turn_tool_calls
  | Force_initial_system_latest_user_turn_tool_calls
  | Force_preserve_always
  | Force_preserve_responses_text
    (** Full plaintext replay on Responses only; other protocols keep their default. *)
  | Force_turn_scoped_system_context_preserve_always
  | Force_preserve_with_request_tools
    (** Replay all prior assistant reasoning exactly when outgoing tools are present. *)

type assistant_tool_content_format =
  | Assistant_tool_content_null
  | Assistant_tool_content_empty_string

(** Which Chat Completions field carries the output-token budget — the classic
    [max_tokens] or the reasoning-era [max_completion_tokens] OpenAI's gpt-5
    family requires. Defaults to {!Chat_max_tokens}. *)
type chat_output_budget_field =
  | Chat_max_tokens
  | Chat_max_completion_tokens

(** Whether the provider rejects enum/oneOf/anyOf/allOf inside function
    parameter schemas (OpenAI's rule). When [Conformant_subset_required],
    the serializer projects tool schemas down to the conformant subset;
    dispatcher-side parameter validation stays authoritative. *)
type tool_schema_conformance =
  | Rich_json_schema
  | Conformant_subset_required

type reasoning_output_format =
  | No_reasoning_output_format
  | Split_reasoning_fields

type structured_output_support =
  | No_structured_output
  | Json_object_only
  | Native_json_schema

type json_schema_dialect =
  | Openai_json_schema
  | Json_object_schema

(** Whether a model also embeds reasoning in the content channel, and in what
    shape. Separate from {!reasoning_streaming_format}, which says how reasoning
    arrives on its own channel: a model can use both at once. *)
type content_inline_reasoning =
  | No_content_inline_reasoning
  | Think_tags
    (** Split tagged content for display; no original Chat carrier authority. *)
  | Think_tags_with_chat_replay
    (** Also retain/replay the original scalar Chat content through a validated witness. *)

type reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
  | Delta_reasoning_field_and_details of string
  | Template_reasoning_streaming

type sampling_parameter =
  | Temperature
  | Top_p
  | Top_k
  | Min_p
  | Presence_penalty
  | Frequency_penalty
  | Seed

type task =
  | Transcription
  | Speech
  | Image_generation
  | Video_generation

type anthropic_thinking_control =
  | Adaptive_default
  | Adaptive_disabled_through_high
  | Adaptive_between_tools
      (** Adaptive by default; disabling up-front thinking uses [between_tools],
          which still thinks between tool calls and permits low/medium/high effort. *)
  | Always_adaptive

type thinking_control_format_fields =
  { label : string
  ; token : string option
  }

type thinking_control_token_invalidity =
  | Empty_token
  | Leading_or_trailing_whitespace

type thinking_control_format_codec_error =
  | Unknown_label of string
  | Token_required
  | Token_forbidden
  | Invalid_token of
      { token : string
      ; invalidity : thinking_control_token_invalidity
      }

val anthropic_thinking_control_values : string list
val anthropic_thinking_control_of_string : string -> anthropic_thinking_control option
val canonical_label_of_thinking_control_format : thinking_control_format -> string
val token_of_thinking_control_format : thinking_control_format -> string option

val encode_thinking_control_format
  :  thinking_control_format
  -> (thinking_control_format_fields, thinking_control_format_codec_error) result

val decode_thinking_control_format
  :  thinking_control_format_fields
  -> (thinking_control_format, thinking_control_format_codec_error) result

val decode_optional_thinking_control_format
  :  label:string option
  -> token:string option
  -> (thinking_control_format option, thinking_control_format_codec_error) result

val thinking_control_format_codec_error_to_string
  :  thinking_control_format_codec_error
  -> string

val preserve_thinking_control_format_values : string list

val preserve_thinking_control_format_of_string
  :  string
  -> preserve_thinking_control_format option

val modality_priority_values : string list
val task_values : string list
val task_of_string : string -> task option
val task_to_string : task -> string
val reasoning_replay_values : string list
val reasoning_replay_override_of_string : string -> reasoning_replay_override option
val assistant_tool_content_format_values : string list

val assistant_tool_content_format_of_string
  :  string
  -> assistant_tool_content_format option

val chat_output_budget_field_values : string list

val chat_output_budget_field_of_string
  :  string
  -> chat_output_budget_field option

val tool_schema_conformance_values : string list

val tool_schema_conformance_of_string
  :  string
  -> tool_schema_conformance option

val reasoning_output_format_values : string list
val reasoning_output_format_of_string : string -> reasoning_output_format option
val content_inline_reasoning_values : string list
val content_inline_reasoning_of_string : string -> content_inline_reasoning option
val reasoning_streaming_format_syntax : string
val reasoning_streaming_format_of_string : string -> reasoning_streaming_format option
val sampling_parameter_values : string list
val sampling_parameter_of_string : string -> sampling_parameter option
val sampling_parameter_to_string : sampling_parameter -> string
val base_label_values : string list
val capability_fields : string list

val json_schema_dialect_values : string list
val json_schema_dialect_of_string : string -> json_schema_dialect option
val json_schema_dialect_to_string : json_schema_dialect -> string
