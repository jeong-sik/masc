(** Typed stream-error projection at the HTTP boundary. *)

(* Scrub-then-bound the offending payload echoed into a parse-failure message.
   Tool arguments can carry credentials (Bearer tokens, API keys, URL userinfo),
   so the buffer passes through the [Secret_redactor] SSOT before it reaches the
   operator-facing message. Redaction runs first so truncation cannot split a
   token past the redactor and leak a partial. *)
let max_parse_error_raw_excerpt = 256

let parse_error_raw_excerpt raw =
  let redacted = Secret_redactor.redact_string raw in
  if String.length redacted <= max_parse_error_raw_excerpt
  then redacted
  else
    Agent_core_strings.utf8_prefix ~max_bytes:max_parse_error_raw_excerpt redacted
    ^ "...(truncated)"
;;

type refused_frame =
  { wire_format : Http_client.provider_wire_format
  ; reason : string
  ; raw : string
  }

type projection =
  { error : Http_client.http_error
  ; diagnostic : refused_frame option
  }

let without_diagnostic error = { error; diagnostic = None }

let malformed_projection ~wire_format ~reason ~raw =
  let wire_label =
    Http_client.provider_wire_format_to_string wire_format |> String.uppercase_ascii
  in
  { error =
      Http_client.ProviderFailure
        { kind =
            Http_client.Provider_wire_error
              { format = wire_format; kind = Http_client.Malformed_payload }
        ; message =
            (match raw with
             | "" -> Printf.sprintf "%s parse failed: %s" wire_label reason
             | raw ->
               Printf.sprintf "%s parse failed: %s raw=%S"
                 wire_label reason (parse_error_raw_excerpt raw))
        }
  ; diagnostic = Some { wire_format; reason; raw }
  }
;;

(* Terminal telemetry labels for stream failures. They live beside the typed
   projection above so a published [Streaming_summary] can never disagree with
   the error it accompanies: both are derived from the same two functions. *)
let provider_reported_terminal_label = "provider_stream_error"
let capability_mismatch_terminal_label = "capability_mismatch"

let wire_error_terminal_label wire_format =
  Http_client.provider_wire_format_to_string wire_format ^ "_wire_error"
;;

(* The label for an [http_error] the stream returns when no event named the
   failure first. A provider condition declared inside the stream is returned
   as [HttpError] ([http_error_of_stream_error] below), so its summary takes
   this label from that returned error rather than
   [provider_reported_terminal_label], which names a returned
   [Provider_reported_error]. *)
let returned_error_terminal_label wire_format (err : Http_client.http_error) =
  Printf.sprintf
    "%s_stream_error: %s"
    (Http_client.provider_wire_format_to_string wire_format)
    (match err with
     | Http_client.NetworkError { message; _ } | Http_client.TimeoutError { message; _ } ->
       message
     | Http_client.HttpError { code; _ } -> Printf.sprintf "HTTP %d" code
     | Http_client.AcceptRejected { reason } -> reason
     | Http_client.ProviderTerminal { message; _ } -> message
     | Http_client.ProviderFailure { message; _ } -> message)
;;

(* A payload unit larger than the reader's limit is neither malformed syntax
   nor a truncated stream: the bytes are well-formed and there are too many of
   them. It gets its own [provider_wire_error_kind] so the classification stays
   a closed type — encoding the size condition into a [reason] string would
   push the distinction back into text a consumer has to parse. Kept in this
   module so every wire error has exactly one construction site. *)
let http_error_of_oversized_payload ~wire_format ~actual_bytes ~limit_bytes
  : Http_client.http_error
  =
  let wire_label =
    Http_client.provider_wire_format_to_string wire_format |> String.uppercase_ascii
  in
  Http_client.ProviderFailure
    { kind =
        Http_client.Provider_wire_error
          { format = wire_format; kind = Http_client.Oversized_payload }
    ; message =
        (match actual_bytes with
         | Some actual_bytes ->
           Printf.sprintf
             "%s payload of %d bytes exceeded the %d byte limit"
             wire_label
             actual_bytes
             limit_bytes
         (* The buffered reader aborts AT the limit, so the payload's true size
            is not observable on that path. Report the bound rather than
            inventing a number. *)
         | None ->
           Printf.sprintf "%s payload exceeded the %d byte limit" wire_label limit_bytes)
    }
;;

let%test "terminal labels name the wire format the failure carries" =
  String.equal (wire_error_terminal_label Http_client.Ndjson) "ndjson_wire_error"
  && String.equal (wire_error_terminal_label Http_client.Sse) "sse_wire_error"
;;

let%test "a returned HttpError is labelled with its status" =
  String.equal
    (returned_error_terminal_label
       Http_client.Sse
       (Http_client.HttpError
          { code = 502; body = Http_client.Received "{}"; retry_after_header = None }))
    "sse_stream_error: HTTP 502"
;;

let%test "a provider-reported envelope is not labelled a wire failure" =
  (not
     (String.equal
        provider_reported_terminal_label
        (wire_error_terminal_label Http_client.Sse)))
  && String.equal provider_reported_terminal_label "provider_stream_error"
;;

let%test "oversized payload remains a typed wire fact" =
  match
    http_error_of_oversized_payload
      ~wire_format:Http_client.Ndjson
      ~actual_bytes:(Some 11)
      ~limit_bytes:10
  with
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Ndjson; kind = Http_client.Oversized_payload }
      ; message = "NDJSON payload of 11 bytes exceeded the 10 byte limit"
      } -> true
  | Http_client.HttpError _
  | Http_client.NetworkError _
  | Http_client.TimeoutError _
  | Http_client.AcceptRejected _
  | Http_client.ProviderTerminal _
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Capability_mismatch _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_reported_error _
          | Http_client.Provider_interrupted
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; _
      }
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Sse | Http_client.Ndjson
            ; kind =
                ( Http_client.Malformed_payload
                | Http_client.Unknown_event
                | Http_client.Incomplete_stream
                | Http_client.Oversized_payload )
            }
      ; _
      } -> false
;;

(* Preserve the distinction between a provider-owned error envelope and a
   response that violates the declared wire contract. Retry policy is
   intentionally not inferred here.

   An envelope that declares a provider condition is the one exception to
   reading it as [Provider_reported_error]: the provider failed after the
   stream's own [200] went out, so it put the status inside the error object
   instead (OpenRouter mid-stream errors). [Openai_error_envelope] carries only
   429 and 5xx, the statuses that describe the provider and mean the same
   before the stream and after; a 4xx reported after the request was accepted
   does not say the request is invalid, so it never arrives here. Such a
   status is the refusal a status line would have been, and it becomes that
   [HttpError], with only the error object as its body, so the classification
   the status gets before the stream ([Retry.classify_refusal]) is the one it
   gets here. [raw] stays out of the body: it is the whole chunk, content
   included. Without a declared condition the envelope stays provider-owned
   diagnostic data. *)
let project_stream_error
      ?(wire_format = Http_client.Sse)
      (serr : Types.stream_error)
  : projection
  =
  let wire_label =
    Http_client.provider_wire_format_to_string wire_format |> String.uppercase_ascii
  in
  match serr with
  | Types.Stream_provider_error
      { provider_status = Some { Types.status; error_body }
      ; message = _
      ; error_type = _
      ; report = _
      ; raw = _
      } ->
    without_diagnostic
      (Http_client.HttpError
         { code = status; body = Http_client.Received error_body; retry_after_header = None })
  | Types.Stream_provider_error
      { message
      ; error_type
      ; provider_status = None
      ; report = Types.Provider_stated
      ; raw
      } ->
    without_diagnostic (Http_client.ProviderFailure
      { kind = Http_client.Provider_reported_error { error_type }
      ; message =
          Printf.sprintf
            "%s stream error: %s raw=%S"
            wire_label
            message
            (parse_error_raw_excerpt raw)
      })
  (* The choice said the generation failed and no error object arrived with
     it: nothing declares a type or a status, and the answer stopped part-way
     for a reason the provider kept to itself. *)
  | Types.Stream_provider_error
      { message
      ; error_type = _
      ; provider_status = None
      ; report = Types.Unstated_errored_choice
      ; raw
      } ->
    without_diagnostic (Http_client.ProviderFailure
      { kind = Http_client.Provider_interrupted
      ; message =
          Printf.sprintf
            "%s stream error: %s raw=%S"
            wire_label
            message
            (parse_error_raw_excerpt raw)
      })
  | Types.Stream_parse_failed { reason; raw } ->
    malformed_projection ~wire_format ~reason ~raw
  | Types.Stream_ndjson_parse_failed { reason; raw } ->
    malformed_projection ~wire_format:Http_client.Ndjson ~reason ~raw
  | Types.Stream_incomplete { reason } ->
    without_diagnostic (Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = wire_format; kind = Http_client.Incomplete_stream }
      ; message = Printf.sprintf "%s stream incomplete: %s" wire_label reason
      })
  | Types.Stream_repeating { repeated; occurrences; bytes_seen; shape } ->
    without_diagnostic (Http_client.ProviderFailure
      { kind =
          Http_client.Repeating_generation
            { shape; occurrences; unit_bytes = String.length repeated }
      ; message = Types.repeating_generation_message ~repeated ~occurrences ~bytes_seen shape
      })
  | Types.Stream_unknown_event { event_type; _ } ->
    without_diagnostic (Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Sse; kind = Http_client.Unknown_event }
      ; message = Printf.sprintf "SSE unknown event type: %s" event_type
      })
  | Types.Stream_unsupported_part { provider_kind; part; raw } ->
    let capability =
      Printf.sprintf "%s.part.%s" (Provider_kind.to_string provider_kind) part
    in
    let message =
      match raw with
      | "" -> Printf.sprintf "provider emitted an unsupported content part: %s" capability
      | raw ->
        Printf.sprintf
          "provider emitted an unsupported content part: %s raw=%S"
          capability
          (parse_error_raw_excerpt raw)
    in
    without_diagnostic (Http_client.ProviderFailure
      { kind = Http_client.Capability_mismatch { capability = Some capability }; message })
  | Types.Stream_unsupported_response { provider_kind; response; raw } ->
    let capability =
      Printf.sprintf "%s.response.%s" (Provider_kind.to_string provider_kind) response
    in
    let message =
      match raw with
      | "" -> Printf.sprintf "provider emitted an unsupported response: %s" capability
      | raw ->
        Printf.sprintf
          "provider emitted an unsupported response: %s raw=%S"
          capability
          (parse_error_raw_excerpt raw)
    in
    without_diagnostic (Http_client.ProviderFailure
      { kind = Http_client.Capability_mismatch { capability = Some capability }; message })
;;

let http_error_of_stream_error ?wire_format serr =
  (project_stream_error ?wire_format serr).error
;;

(* A choice that finished with [error] and carried no error object: nothing
   declares a type or a status, so the failure says the generation was
   interrupted rather than reporting an envelope that never arrived. *)
let%test "an errored choice with no object reads as an interrupted generation" =
  match
    Streaming.parse_openai_sse_chunk
      ~streaming_reasoning:Reasoning_dialect.No_streaming_reasoning
      {|{"id":"c","choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"error"}]}|}
  with
  | Streaming.Openai_provider_error { message; error_type; provider_status; report; raw } ->
    report = Types.Unstated_errored_choice
    &&
    (match
       http_error_of_stream_error
         (Types.Stream_provider_error
            { message; error_type; provider_status; report; raw })
     with
     (* The kind is the fact under test. The message is display text built by
        the same printf as its siblings, and the wire-format test below covers
        that shape. *)
     | Http_client.ProviderFailure { kind = Http_client.Provider_interrupted; message = _ } ->
       true
     | Http_client.ProviderFailure
         { kind =
             ( Http_client.Capacity_exhausted _
             | Http_client.Hard_quota _
             | Http_client.Capability_mismatch _
             | Http_client.Cli_policy_invalid _
             | Http_client.Cli_startup_failed _
             | Http_client.Provider_parse_error _
             | Http_client.Provider_wire_error _
             | Http_client.Provider_reported_error _
             | Http_client.Response_body_too_large _
             | Http_client.Empty_completion _
             | Http_client.Context_overflow _
             | Http_client.Repeating_generation _
             | Http_client.Unknown_provider_failure _ )
         ; _
         }
     | Http_client.HttpError _
     | Http_client.NetworkError _ | Http_client.TimeoutError _
     | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false)
  | Streaming.Openai_chunk _
  | Streaming.Openai_done
  | Streaming.Openai_empty
  | Streaming.Openai_parse_failed _
  | Streaming.Openai_undeclared_reasoning_member _ -> false
;;

let%test "generic stream provider type stays diagnostic" =
  match
    http_error_of_stream_error
      (Types.Stream_provider_error
         { message = "provider refused"
         ; error_type = Some "provider_owned_type"
         ; provider_status = None
         ; report = Types.Provider_stated
         ; raw = "{}"
         })
  with
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_reported_error { error_type = Some "provider_owned_type" }
      ; _
      } -> true
  | Http_client.HttpError _
  | Http_client.NetworkError _
  | Http_client.TimeoutError _
  | Http_client.AcceptRejected _
  | Http_client.ProviderTerminal _
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Capability_mismatch _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_wire_error _
          | Http_client.Provider_interrupted
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; _
      }
  | Http_client.ProviderFailure { kind = Http_client.Provider_reported_error _; _ } -> false
;;

(* End to end from the chunk text: a choice-level error that declares 429
   classifies from its own object -- [message] and [retry_after] -- and nothing
   else the chunk carried reaches the refusal body. *)
let%test "a choice-level 429 is a rate limit classified from its error object alone" =
  let chunk =
    {|{"id":"c","model":"m","choices":[{"index":0,"delta":{"content":"partial answer","tool_calls":[{"index":0,"function":{"arguments":"{\"token\":\"t\"}"}}]},"finish_reason":"error","error":{"code":429,"message":"slow down","retry_after":7.0}}],"usage":{"prompt_tokens":3}}|}
  in
  match
    Streaming.parse_openai_sse_chunk
      ~streaming_reasoning:Reasoning_dialect.No_streaming_reasoning
      chunk
  with
  | Streaming.Openai_provider_error { message; error_type; provider_status; report; raw } ->
    (match
       http_error_of_stream_error
         (Types.Stream_provider_error
            { message; error_type; provider_status; report; raw })
     with
     | Http_client.HttpError
         { code = 429; body = Http_client.Received body; retry_after_header = None } ->
       String.equal body {|{"error":{"code":429,"message":"slow down","retry_after":7.0}}|}
       &&
       (match
          Retry.classify_refusal
            ~retry_after_header:None
            ~status:429
            ~body:(Http_client.Received body)
        with
        | Retry.RateLimited { retry_after = Some retry_after; message } ->
          Float.equal retry_after 7.0 && String.equal message "slow down"
        | Retry.RateLimited { retry_after = None; message = _ } | Retry.Overloaded _
        | Retry.ServerError _ | Retry.AuthError _ | Retry.AuthorizationError _
        | Retry.PaymentRequired _ | Retry.InvalidRequest _ | Retry.NotFound _
        | Retry.ContextOverflow _ | Retry.InputCapacity _ | Retry.NetworkError _ | Retry.Timeout _ -> false)
     | Http_client.HttpError
         { body = Http_client.Received _ | Http_client.Not_received_in_window; _ }
     | Http_client.NetworkError _
     | Http_client.TimeoutError _
     | Http_client.AcceptRejected _
     | Http_client.ProviderTerminal _
     | Http_client.ProviderFailure
         { kind =
             ( Http_client.Capacity_exhausted _
             | Http_client.Hard_quota _
             | Http_client.Capability_mismatch _
             | Http_client.Cli_policy_invalid _
             | Http_client.Cli_startup_failed _
             | Http_client.Provider_parse_error _
             | Http_client.Provider_wire_error _
             | Http_client.Provider_reported_error _
             | Http_client.Provider_interrupted
             | Http_client.Response_body_too_large _
             | Http_client.Empty_completion _
             | Http_client.Context_overflow _
             | Http_client.Repeating_generation _
             | Http_client.Unknown_provider_failure _ )
         ; _
         } -> false)
  | Streaming.Openai_chunk _
  | Streaming.Openai_done
  | Streaming.Openai_empty
  | Streaming.Openai_parse_failed _
  | Streaming.Openai_undeclared_reasoning_member _ -> false
;;

let%test "a top-level 502 is a server error and a 4xx code stays provider-owned" =
  let parse code =
    Streaming.parse_openai_sse_chunk
      ~streaming_reasoning:Reasoning_dialect.No_streaming_reasoning
      (Printf.sprintf
         {|{"id":"c","model":"m","error":{"code":%d,"message":"Provider disconnected","metadata":{"error_type":"provider_unavailable"}},"choices":[{"index":0,"delta":{"content":""},"finish_reason":"error"}]}|}
         code)
  in
  let http_error = function
    | Streaming.Openai_provider_error { message; error_type; provider_status; report; raw } ->
      Some
        (http_error_of_stream_error
           (Types.Stream_provider_error
              { message; error_type; provider_status; report; raw }))
    | Streaming.Openai_chunk _
    | Streaming.Openai_done
    | Streaming.Openai_empty
    | Streaming.Openai_parse_failed _
    | Streaming.Openai_undeclared_reasoning_member _ -> None
  in
  (match http_error (parse 502) with
   | Some (Http_client.HttpError { code = 502; body; retry_after_header = None }) ->
     (match Retry.classify_refusal ~retry_after_header:None ~status:502 ~body with
      | Retry.ServerError { status = 502; message } ->
        String.equal message "Provider disconnected"
      | Retry.ServerError _
      | Retry.RateLimited _
      | Retry.Overloaded _
      | Retry.AuthError _
      | Retry.AuthorizationError _
      | Retry.PaymentRequired _
      | Retry.InvalidRequest _
      | Retry.NotFound _
      | Retry.ContextOverflow _
      | Retry.InputCapacity _
      | Retry.NetworkError _
      | Retry.Timeout _ -> false)
   | None
   | Some
       ( Http_client.HttpError
           { body = Http_client.Received _ | Http_client.Not_received_in_window; _ }
       | Http_client.NetworkError _
       | Http_client.TimeoutError _
       | Http_client.AcceptRejected _
       | Http_client.ProviderTerminal _
       | Http_client.ProviderFailure
           { kind =
               ( Http_client.Capacity_exhausted _
               | Http_client.Hard_quota _
               | Http_client.Capability_mismatch _
               | Http_client.Cli_policy_invalid _
               | Http_client.Cli_startup_failed _
               | Http_client.Provider_parse_error _
               | Http_client.Provider_wire_error _
               | Http_client.Provider_reported_error _
               | Http_client.Provider_interrupted
               | Http_client.Response_body_too_large _
               | Http_client.Empty_completion _
               | Http_client.Context_overflow _
               | Http_client.Repeating_generation _
               | Http_client.Unknown_provider_failure _ )
           ; _
           } ) -> false)
  &&
  match http_error (parse 403) with
  | Some
      (Http_client.ProviderFailure
         { kind =
             Http_client.Provider_reported_error { error_type = Some "provider_unavailable" }
         ; _
         }) -> true
  | None
  | Some
      ( Http_client.HttpError _
      | Http_client.NetworkError _
      | Http_client.TimeoutError _
      | Http_client.AcceptRejected _
      | Http_client.ProviderTerminal _
      | Http_client.ProviderFailure
          { kind =
              ( Http_client.Capacity_exhausted _
              | Http_client.Hard_quota _
              | Http_client.Capability_mismatch _
              | Http_client.Cli_policy_invalid _
              | Http_client.Cli_startup_failed _
              | Http_client.Provider_parse_error _
              | Http_client.Provider_wire_error _
              | Http_client.Provider_reported_error _
              | Http_client.Provider_interrupted
              | Http_client.Response_body_too_large _
              | Http_client.Empty_completion _
              | Http_client.Context_overflow _
              | Http_client.Repeating_generation _
              | Http_client.Unknown_provider_failure _ )
          ; _
          } ) -> false
;;

let%test "provider error diagnostic uses the active wire format" =
  match
    http_error_of_stream_error
      ~wire_format:Http_client.Ndjson
      (Types.Stream_provider_error
         { message = "provider refused"
         ; error_type = None
         ; provider_status = None
         ; report = Types.Provider_stated
         ; raw = "{}"
         })
  with
  | Http_client.ProviderFailure { message; _ } ->
    message = "NDJSON stream error: provider refused raw=\"{}\""
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] maps_to_sse_wire_failure ~expected_kind stream_error =
  match http_error_of_stream_error stream_error with
  | Http_client.ProviderFailure
      { kind = Http_client.Provider_wire_error { format = Http_client.Sse; kind }; _ } ->
    kind = expected_kind
  | Http_client.HttpError _
  | Http_client.NetworkError _
  | Http_client.TimeoutError _
  | Http_client.AcceptRejected _
  | Http_client.ProviderTerminal _
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Capability_mismatch _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_reported_error _
          | Http_client.Provider_interrupted
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; _
      }
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Ndjson
            ; kind =
                ( Http_client.Malformed_payload
                | Http_client.Unknown_event
                | Http_client.Incomplete_stream
                | Http_client.Oversized_payload )
            }
      ; _
      } -> false
;;

let%test "stream parse failure is malformed wire evidence" =
  maps_to_sse_wire_failure
    ~expected_kind:Http_client.Malformed_payload
    (Types.Stream_parse_failed { reason = "bad json"; raw = "x" })
;;

let%test "semantic parse failure uses the active NDJSON wire format" =
  match
    http_error_of_stream_error
      ~wire_format:Http_client.Ndjson
      (Types.Stream_parse_failed { reason = "bad shape"; raw = "{}" })
  with
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Ndjson; kind = Http_client.Malformed_payload }
      ; message
      } -> message = "NDJSON parse failed: bad shape raw=\"{}\""
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Ndjson
            ; kind =
                ( Http_client.Unknown_event
                | Http_client.Incomplete_stream
                | Http_client.Oversized_payload )
            }
      ; message = _
      }
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Sse
            ; kind =
                ( Http_client.Malformed_payload
                | Http_client.Unknown_event
                | Http_client.Incomplete_stream
                | Http_client.Oversized_payload )
            }
      ; message = _
      }
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Provider_interrupted
          | Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Capability_mismatch _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_reported_error _
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; message = _
      }
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

let%test "stream incompleteness remains distinct from malformed payload" =
  match
    http_error_of_stream_error
      (Types.Stream_incomplete { reason = "terminal marker missing" })
  with
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Sse; kind = Http_client.Incomplete_stream }
      ; message
      } -> message = "SSE stream incomplete: terminal marker missing"
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Sse
            ; kind =
                ( Http_client.Malformed_payload
                | Http_client.Unknown_event
                | Http_client.Oversized_payload )
            }
      ; message = _
      }
  | Http_client.ProviderFailure
      { kind =
          Http_client.Provider_wire_error
            { format = Http_client.Ndjson
            ; kind =
                ( Http_client.Malformed_payload
                | Http_client.Unknown_event
                | Http_client.Incomplete_stream
                | Http_client.Oversized_payload )
            }
      ; message = _
      }
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Provider_interrupted
          | Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Capability_mismatch _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_reported_error _
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; message = _
      }
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

let%test "parse failure echoes the offending raw buffer for diagnosis" =
  let reason = "malformed_tool_use_arguments:index:1:bad" in
  let raw = {|{"location":"Tokyo"}{}|} in
  match http_error_of_stream_error (Types.Stream_parse_failed { reason; raw }) with
  | Http_client.ProviderFailure { message; _ } ->
    message = Printf.sprintf "SSE parse failed: %s raw=%S" reason raw
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

let%test "parse failure raw excerpt is bounded" =
  let reason = "malformed_tool_use_arguments:index:0:bad" in
  let raw = String.make 1000 'x' in
  match http_error_of_stream_error (Types.Stream_parse_failed { reason; raw }) with
  | Http_client.ProviderFailure { message; _ } ->
    String.length message < String.length raw
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

let%test "parse failure redacts authorization values in the echoed raw buffer" =
  let reason = "malformed_tool_use_arguments:index:0:bad" in
  let raw = {|{"auth":"Bearer opaque-token"}{}|} in
  match http_error_of_stream_error (Types.Stream_parse_failed { reason; raw }) with
  | Http_client.ProviderFailure { message; _ } ->
    message
    = Printf.sprintf
        "SSE parse failed: %s raw=%S"
        reason
        {|{"auth":"Bearer [REDACTED]"}{}|}
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

let%test "stream unknown event is wire evidence" =
  maps_to_sse_wire_failure
    ~expected_kind:Http_client.Unknown_event
    (Types.Stream_unknown_event { event_type = "surprise"; raw = "event: surprise" })
;;

let%test "unsupported content part is a capability mismatch" =
  match
    http_error_of_stream_error
      (Types.Stream_unsupported_part
         { provider_kind = Provider_kind.Gemini; part = "executableCode"; raw = "{}" })
  with
  | Http_client.ProviderFailure
      { kind = Http_client.Capability_mismatch { capability = Some capability }; message }
    ->
    capability = "gemini.part.executableCode"
    && message
       = "provider emitted an unsupported content part: gemini.part.executableCode \
          raw=\"{}\""
  | Http_client.ProviderFailure { kind = Http_client.Capability_mismatch { capability = None }; message = _ }
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Provider_interrupted
          | Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_wire_error _
          | Http_client.Provider_reported_error _
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; message = _
      }
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;

let%test "unsupported response is a capability mismatch" =
  match
    http_error_of_stream_error
      (Types.Stream_unsupported_response
         { provider_kind = Provider_kind.Gemini; response = "candidates"; raw = "{}" })
  with
  | Http_client.ProviderFailure
      { kind = Http_client.Capability_mismatch { capability = Some capability }; message }
    ->
    capability = "gemini.response.candidates"
    && message
       = "provider emitted an unsupported response: gemini.response.candidates raw=\"{}\""
  | Http_client.ProviderFailure { kind = Http_client.Capability_mismatch { capability = None }; message = _ }
  | Http_client.ProviderFailure
      { kind =
          ( Http_client.Provider_interrupted
          | Http_client.Capacity_exhausted _
          | Http_client.Hard_quota _
          | Http_client.Cli_policy_invalid _
          | Http_client.Cli_startup_failed _
          | Http_client.Provider_parse_error _
          | Http_client.Provider_wire_error _
          | Http_client.Provider_reported_error _
          | Http_client.Response_body_too_large _
          | Http_client.Empty_completion _
          | Http_client.Context_overflow _
          | Http_client.Repeating_generation _
          | Http_client.Unknown_provider_failure _ )
      ; message = _
      }
  | Http_client.HttpError _ | Http_client.NetworkError _ | Http_client.TimeoutError _
  | Http_client.AcceptRejected _ | Http_client.ProviderTerminal _ -> false
;;
