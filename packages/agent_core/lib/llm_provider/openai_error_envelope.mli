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
    (** The object's [type] (OpenAI's discriminator); when it has none,
        OpenRouter's [metadata.error_type]. Diagnostic only: it rides
        [Http_client.Provider_reported_error], whose contract is that
        agent_core infers no retry semantics from it. *)
  ; provider_status : Types.provider_status option
    (** A numeric [code] that states the provider's condition: [429] (Too Many
        Requests, RFC 6585 section 4) or [500]-[599] (the server error class,
        RFC 9110 section 15.6). Those describe the provider -- rate limited,
        or failing itself -- and mean the same before the stream started and
        after. The body is only this error object ({!Types.provider_status}).

        Every other [code] is not used, [None]:
        - Any other number, including [400], [401], [402], [403] and [413].
          The request had already been accepted when the [200] went out, so a
          [4xx] reported after it does not mean this request is invalid, and
          OpenRouter's errors reference tells readers to use
          [metadata.error_type], "not the HTTP status code alone", to tell its
          error categories apart. A number outside the HTTP range (e.g.
          [1261]) is a vendor's own code.
        - A string [code]: OpenAI's own ([rate_limit_exceeded]) and glm's
          (["1261"]) name no status.

        OpenRouter's errors reference types a mid-stream [error.code] as the
        HTTP status number (e.g. [429], [502]); its streaming reference's
        mid-stream example carries the string ["server_error"] instead. Both
        shapes are read; only the first can declare a status.
        (https://openrouter.ai/docs/api_reference/errors-and-debugging.md,
        https://openrouter.ai/docs/api_reference/streaming.md) *)
  ; report : Types.provider_report
    (** Whether an [error] member arrived at all. The values above are read
        from one; a choice that finished with [error] and carried none has
        nothing to read, and says so here rather than through an absent
        [error_type], which an object without a [type] also produces. *)
  }

(** An [error] member's value: an object, or a bare message string
    (Ollama / llama.cpp), which declares no status. [fallback_message] is the
    message when an object has no string [message]. [None] for any other JSON
    value. *)
val of_error_value : fallback_message:string -> Yojson.Safe.t -> t option

(** The error a choice that finished with [error] reports: its [error] member
    when {!of_error_value} reads one, otherwise a message saying the choice
    carried none. A choice may carry neither -- the finish reason alone still
    says the provider failed. *)
val of_errored_choice : fallback_message:string -> Yojson.Safe.t -> t
