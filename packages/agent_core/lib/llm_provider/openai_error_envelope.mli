(** The error object an OpenAI-compatible provider reports inside a response it
    has already accepted: the top-level [error] member of a response or stream
    chunk, or the [error] member of a choice that finished with [error]
    ({!Stop_reason_wire.is_provider_error_finish}).

    One reader for the streaming chunk parser and the non-streaming response
    parser, so a status the provider declares reaches the same classification
    whichever way the response arrived. *)

type t =
  { message : string
  ; error_type : string option
    (** The object's [type], OpenAI's discriminator; [None] when absent. *)
  ; http_status : int option
    (** A numeric [code] from 100 to 599 (RFC 9110 section 15): the HTTP status
        the provider declares for the failure, because the response's own
        [200] had already been sent. OpenRouter's mid-stream error carries
        [code: number] from the table of its HTTP errors
        (openrouter.ai/docs/api-reference/errors), as vLLM does. [None] for a
        string [code] -- OpenAI's own, glm's ["1261"] -- or a number outside
        that range. *)
  }

(** An [error] member's value: an object, or a bare message string
    (Ollama / llama.cpp). [fallback_message] is the message when an object has
    no string [message]. [None] for any other JSON value. *)
val of_error_value : fallback_message:string -> Yojson.Safe.t -> t option

(** The error a choice that finished with [error] reports: its [error] member
    when {!of_error_value} reads one, otherwise a message saying the choice
    carried none. A choice may carry neither -- the finish reason alone still
    says the provider failed. *)
val of_errored_choice : fallback_message:string -> Yojson.Safe.t -> t
