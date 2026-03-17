(** Llm_transport — UTF-8 sanitization, endpoint resolution, and legacy JSON encoding.
    @since 2.103.0 *)

open Llm_types

val sanitize_text_utf8 : string -> string
val sanitize_message_utf8 : message -> message
val sanitize_messages_utf8 : message list -> message list
val message_to_openai_json : message -> Yojson.Safe.t
val get_api_key : model_spec -> string
val fetch_vertex_adc_access_token : unit -> (string, string) result
val resolve_openai_compatible_endpoint :
  model_spec -> (string * string * (string * string) list, string) result
