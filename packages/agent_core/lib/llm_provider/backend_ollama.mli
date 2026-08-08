(** Ollama native API backend.

    Builds requests for [/api/chat] endpoint with [think] parameter
    except for Gemma 4 chat-template thinking, and parses native API responses.

    @since 0.113.0 *)

type request_artifact

val request_payload : request_artifact -> string
val request_output_token_receipt : request_artifact -> Types.output_token_receipt

val build_request_artifact
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> request_artifact

val build_request
  :  ?stream:bool
  -> config:Provider_config.t
  -> messages:Types.message list
  -> ?tools:Yojson.Safe.t list
  -> unit
  -> string

val parse_ollama_response : string -> (Types.api_response, string) result
