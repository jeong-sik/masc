(** Server Flavor Adapter — public interface. *)

type cascade_server_flavor = Cascade_phonebook_types.cascade_server_flavor =
  | Llama_cpp | Ollama | Vllm | Provider_d_wire | Provider_g_wire | Provider_k_zai | Provider_h_wire

type flavor_error =
  | Business_error of { code : int; message : string }
  | Content_filter of string
  | Tools_stream_incompatible
  | Reasoning_budget_exceeded
  | Unknown_finish_reason of string
[@@deriving show, eq]

type thinking_control =
  | No_thinking
  | Deep_seek_thinking of { enabled : bool }
  | Llama_cpp_thinking of { enable : bool; budget : int option }
  | Openai_reasoning_effort of { effort : string }
  | Ollama_think of { think : bool }
[@@deriving show, eq]

val thinking_control_for_flavor :
  cascade_server_flavor -> bool -> int option -> thinking_control

type finish_reason = Stop | Length | Tool_calls | Content_filter | Error
[@@deriving show, eq]

val finish_reason_of_string : cascade_server_flavor -> string option -> finish_reason

type stream_chunk =
  | Content_delta of string
  | Thinking_delta of string
  | Tool_call of { index : int; id : string; name : string; arguments : string }
  | Finish of finish_reason
  | Usage of { input_tokens : int; output_tokens : int }
  | Done
[@@deriving show, eq]

type flavor_constraints = {
  supports_tools_with_streaming : bool;
  supports_response_format : bool;
  supports_parallel_tool_calls : bool;
  finish_reason_nullable : bool;
  arguments_as_json_object : bool;
}
[@@deriving show, eq]

val constraints_of_flavor : cascade_server_flavor -> flavor_constraints
val can_stream_with_tools : cascade_server_flavor -> bool
