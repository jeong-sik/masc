(** OpenAI-compatible response parsing.

    @since 0.92.0 extracted from Backend_openai

    @stability Internal
    @since 0.93.1 *)

val usage_of_openai_json : Yojson.Safe.t -> Types.api_usage option

(** Identity of an all-empty completion (oas#2483): a 200 that carried no
    thinking, text, or tool_calls. Enough for a consumer to attribute the empty
    turn to a runtime binding. *)
type empty_completion =
  { id : string
  ; model : string
  ; stop_reason : Types.stop_reason
  ; usage : Types.api_usage option
  ; telemetry : Types.inference_telemetry option
  }

(** Parse failure. [Provider_error] is a provider-reported API error (the JSON
    [error] body). [Empty_completion] is a fail-closed all-empty 200 that would
    otherwise have parsed as [Ok content=[]] and stormed downstream. *)
type parse_error =
  | Provider_error of string
  | Empty_completion of empty_completion

(** Human-readable rendering of a {!parse_error} for logs / test failures. *)
val parse_error_to_string : parse_error -> string

(** Parse an OpenAI-compatible JSON response (from an already-parsed
    [Yojson.Safe.t]).  [Ok api_response] on success; [Error (Provider_error _)]
    on API error; [Error (Empty_completion _)] when the completion has no
    thinking/text/tool_calls (oas#2483). Blank text WITH tool_calls stays [Ok]
    (content is non-empty). Use when the caller already holds the parsed JSON to
    avoid re-parsing. *)
val parse_openai_response_result_json
  :  Yojson.Safe.t
  -> (Types.api_response, parse_error) result

(** Parse an OpenAI-compatible JSON response. See
    {!parse_openai_response_result_json} for the [parse_error] contract. *)
val parse_openai_response_result : string -> (Types.api_response, parse_error) result
