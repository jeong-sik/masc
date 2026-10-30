(** Ollama native API backend.

    Builds requests for [/api/chat] endpoint with [think] parameter
    except for Gemma 4 chat-template thinking, and parses native API responses.

    @since 0.113.0 *)
(** [tools_present] is the effective outgoing tools-array presence. Omission
    describes a request without tools; sizing callers must pass the same fact
    as serialization. *)
val project_history
  :  ?tools_present:bool
  -> Provider_config.t
  -> 'source Types.message_with list
  -> ('source Reasoning_history_projection.projection, Reasoning_history_projection.error) result
(** The history this codec will actually serialize: reasoning blocks it cannot
    carry, and blocks the config's replay policy excludes, are already gone.

    Exported so a caller that must size a request before building it asks the
    same function the wire does, rather than keeping a second opinion about
    which blocks survive. Pure — the diagnostic [observe] belongs to whoever
    dispatches. *)


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

val parse_ollama_response : ?content_inline_reasoning:Capabilities.content_inline_reasoning -> string -> (Types.api_response, string) result
