(** Llm_transport — HTTP execution, JSON encoding/parsing, and UTF-8 sanitization for LLM providers. *)

open Llm_types

(** Replace invalid UTF-8 byte sequences with U+FFFD replacement character. *)
val sanitize_text_utf8 : string -> string

(** Sanitize all string fields of a message for valid UTF-8. *)
val sanitize_message_utf8 : message -> message

(** Sanitize all messages in a list for valid UTF-8. *)
val sanitize_messages_utf8 : message list -> message list

(** Call the Anthropic Messages API (Claude). *)
val call_claude : ?timeout_sec:int -> completion_request -> (completion_response, string) result

(** Call an OpenAI-compatible endpoint (llama.cpp, Gemini, GLM, OpenRouter, etc.). *)
val call_openai_compatible : ?timeout_sec:int -> completion_request -> (completion_response, string) result

(** GLM Cloud call with pool-based load balancing. *)
val call_glm_cloud_with_pool : ?timeout_sec:int -> completion_request -> (completion_response, string) result
