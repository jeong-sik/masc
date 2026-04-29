(** Server_openai_compat — opt-in OpenAI Chat Completions compat
    endpoint.

    Routes [POST /v1/chat/completions] to either a keeper turn (when
    [model] starts with [keeper:]) or a direct MASC named-cascade
    execution otherwise.  Request / response shape follows the
    OpenAI Chat Completions API spec.

    Opt-in via [MASC_OPENAI_COMPAT=1] (delegated to
    {!Env_config.Transport.openai_compat_enabled}). *)

val is_enabled : unit -> bool
(** [is_enabled ()] returns the value of
    {!Env_config.Transport.openai_compat_enabled}.  Default
    [false].  The HTTP route in [bin/main_eio.ml] short-circuits
    on this predicate before parsing the request body. *)

val error_response :
  status:string -> message:string -> string
(** [error_response ~status ~message] returns the JSON-string
    error envelope:
    {[
      `Assoc [
        ("error", `Assoc [
          ("message", `String message);
          ("type", `String status);
          ("param", `Null);
          ("code", `Null);
        ])
      ]
    ]}
    The wire shape matches OpenAI's [errors.error] field structure
    so OpenAI SDK clients parse it correctly.  The four-key
    [error] sub-object is pinned at the contract seam — the
    [param] / [code] fields are always [`Null] in our compat
    layer (we do not yet differentiate per-field validation
    errors). *)

val handle_chat_completions :
  config:Coord.config ->
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  string ->
  Httpun.Status.t * string
(** [handle_chat_completions ~config ~sw ~clock body] parses the
    OpenAI-format request body and returns
    [(http_status, response_json_string)].

    {2 Routing}

    | Condition | Route |
    |---|---|
    | [model] starts with [keeper:] (length > 7) | {!Keeper_turn.handle_keeper_msg} |
    | otherwise | {!Oas_worker.run_named} with cascade [default_models] |

    The [keeper:] prefix length check (`> 7`) is intentional: an
    empty keeper name (`model = "keeper:"`) falls through to the
    cascade path rather than dispatching to an unnamed keeper.

    {2 Error contract}

    | Condition | HTTP status | Error type |
    |---|---|---|
    | Missing or empty [model] | `Bad_request` | `invalid_request_error` |
    | No user message in [messages] array | `Bad_request` | `invalid_request_error` |
    | Keeper / cascade returned [Error] | `Internal_server_error` | `server_error` |
    | Body is not valid JSON | `Bad_request` | `invalid_request_error` |

    {2 Field defaults}

    | Field | Default |
    |---|---|
    | [max_tokens] | {!Oas_worker_cascade.default_max_tokens} |
    | [temperature] | {!Oas_worker_cascade.default_temperature} |
    | [system] (concat of all system messages) | empty string |

    {2 Response shape}

    On success: an OpenAI-format chat-completion JSON with one
    [choice] (index 0, role "assistant", finish_reason "stop") and
    a zero-filled [usage] block.  Token usage tracking is not
    threaded through {!Masc_oas_bridge.run_with_caller} yet, so
    operators relying on these counts must use the native MCP
    transport instead. *)
