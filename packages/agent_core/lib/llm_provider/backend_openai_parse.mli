(** OpenAI-compatible response parsing.

    @since 0.92.0 extracted from Backend_openai

    @stability Internal
    @since 0.93.1 *)

val usage_of_openai_json : Yojson.Safe.t -> Types.api_usage option

(** Identity of an all-empty completion (agent-core boundary): a 200 that carried no
    thinking, text, or tool_calls. Enough for a consumer to attribute the empty
    turn to a runtime binding. *)
type empty_completion =
  { id : string
  ; model : string
  ; stop_reason : Types.stop_reason
  ; usage : Types.api_usage option
  ; telemetry : Types.inference_telemetry option
  }

(** Parse failure.

    [Provider_error] is an error the provider reported: a top-level [error]
    object or string, or the [error] of a choice that finished with [error]
    (a choice that finished with [error] and carries no error object is one
    too). [error_type] is the object's [type], or OpenRouter's
    [metadata.error_type]; it is diagnostic only. [provider_status] is set only
    when the object's numeric [code] is 429 or 5xx, the statuses that describe
    the provider and mean the same whether or not the response had started;
    any other code, a string code, or no code leaves it [None]
    ({!Types.provider_status} carries the body the refusal is classified
    from).

    [Unreadable_response] is a body this parser cannot read: no
    [finish_reason], malformed tool calls or reasoning, or a top-level [error]
    that is neither an object nor a string. It is not the provider reporting
    anything.

    [Empty_completion] is a fail-closed all-empty 200 that would otherwise have
    parsed as [Ok content=[]] and stormed downstream. *)
type parse_error =
  | Provider_error of
      { message : string
      ; error_type : string option
      ; provider_status : Types.provider_status option
      ; report : Types.provider_report
      }
  | Unreadable_response of string
  | Empty_completion of empty_completion

(** Human-readable rendering of a {!parse_error} for logs / test failures. *)
val parse_error_to_string : parse_error -> string

(** Parse an OpenAI-compatible JSON response (from an already-parsed
    [Yojson.Safe.t]).  [Ok api_response] on success; [Error (Provider_error _)]
    when the provider reported an error; [Error (Unreadable_response _)] when
    the body cannot be read; [Error (Empty_completion _)] when the completion has no
    thinking/text/tool_calls (agent-core boundary). Blank text WITH tool_calls stays [Ok]
    (content is non-empty). Use when the caller already holds the parsed JSON to
    avoid re-parsing.

    [content_inline_reasoning] is the catalog-declared contract for reasoning
    embedded in the content channel; [Think_tags] splits [<think>] markup out of
    [message.content] into a [Thinking] block, while the default
    [No_content_inline_reasoning] keeps [content] byte-identical in [Text]. *)
val parse_openai_response_result_json
  :  ?content_inline_reasoning:Capabilities.content_inline_reasoning
  -> Yojson.Safe.t
  -> (Types.api_response, parse_error) result

(** Parse an OpenAI-compatible JSON response. See
    {!parse_openai_response_result_json} for the [parse_error] contract. *)
val parse_openai_response_result
  :  ?content_inline_reasoning:Capabilities.content_inline_reasoning
  -> string
  -> (Types.api_response, parse_error) result
