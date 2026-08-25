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
  | Enable_thinking

type preserve_thinking_control_format =
  | No_preserve_thinking_control
  | Thinking_object_keep_all
  | Chat_template_kwargs_preserve_thinking
  | Top_level_preserve_thinking
  | Always_preserved_thinking
  | Thinking_object_clear_thinking

type reasoning_replay_override =
  | Default_reasoning_replay
  | Force_no_replay
  | Force_drop_without_tool_preserve_with_tool
  | Force_latest_user_turn_tool_calls
  | Force_preserve_always

type assistant_tool_content_format =
  | Assistant_tool_content_null
  | Assistant_tool_content_empty_string

type reasoning_output_format =
  | No_reasoning_output_format
  | Split_reasoning_fields

type structured_output_support =
  | No_structured_output
  | Json_object_only
  | Native_json_schema

type reasoning_streaming_format =
  | Default_reasoning_streaming
  | No_reasoning_streaming
  | Delta_reasoning_field of string
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
  | Manual_budget
  | Adaptive_default
  | Adaptive_preferred
  | Adaptive_only
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

val structured_output_support_to_string : structured_output_support -> string
val anthropic_thinking_control_values : string list
val anthropic_thinking_control_of_string : string -> anthropic_thinking_control option
val canonical_label_of_thinking_control_format : thinking_control_format -> string
val thinking_control_format_values : string list
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

val preserve_wire_owns_thinking_object : preserve_thinking_control_format -> bool
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

val reasoning_output_format_values : string list
val reasoning_output_format_of_string : string -> reasoning_output_format option
val reasoning_streaming_format_values : string list
val reasoning_streaming_format_syntax : string
val reasoning_streaming_format_of_string : string -> reasoning_streaming_format option
val sampling_parameter_values : string list
val sampling_parameter_of_string : string -> sampling_parameter option
val sampling_parameter_to_string : sampling_parameter -> string
val base_label_values : string list
val capability_fields : string list
