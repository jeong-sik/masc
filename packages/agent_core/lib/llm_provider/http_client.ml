(** HTTP client for LLM provider endpoints.

    Wraps Eio + cohttp-eio with TLS. All network and HTTP-level errors
    are captured as {!http_error} so callers do not need [try/with].

    Each synchronous request without a [connection_cache] creates a one-shot
    client and explicitly closes the underlying TCP connection as soon as the
    response body is fully consumed. With a cache, connections are bound to
    the cache's switch and reused until eviction or switch release.

    @since 0.45.0 *)

open Result_syntax

let is_success_status status = status >= 200 && status < 300

type network_error_kind =
  | Connection_refused
  | Dns_failure
  | Tls_error
  | Timeout
  | Local_resource_exhaustion
  | Connection_reset
  | End_of_file
  | Unknown

type stream_production =
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown
[@@deriving yojson, show]

type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Producing of stream_production
[@@deriving yojson, show]

type timeout_phase =
  | Queue
  | First_token
  | Wall_clock
  | Capacity_backpressure
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_production
  | Provider_step
  | Cli_stdout_idle
  | Unknown_timeout
[@@deriving yojson, show]

type provider_terminal_kind =
  | Session_conflict
  | Other of string

type provider_failure_scope =
  | Failure_scope_model
  | Failure_scope_account
  | Failure_scope_region
  | Failure_scope_provider
  | Failure_scope_unknown

type cli_startup_failure_reason =
  | Executable_unavailable
  | Authentication_unavailable
  | Session_conflict_at_startup
  | Configuration_invalid
  | Unknown_cli_startup_failure
[@@deriving yojson, show]

type provider_wire_format =
  | Sse
  | Ndjson

type provider_wire_error_kind =
  | Malformed_payload
  | Unknown_event
  | Incomplete_stream
  | Oversized_payload

let cli_startup_failure_reason_to_string = function
  | Executable_unavailable -> "executable_unavailable"
  | Authentication_unavailable -> "authentication_unavailable"
  | Session_conflict_at_startup -> "session_conflict"
  | Configuration_invalid -> "configuration_invalid"
  | Unknown_cli_startup_failure -> "unknown"
;;

let provider_wire_format_to_string = function
  | Sse -> "sse"
  | Ndjson -> "ndjson"
;;

let provider_wire_error_kind_to_string = function
  | Malformed_payload -> "malformed_payload"
  | Unknown_event -> "unknown_event"
  | Incomplete_stream -> "incomplete_stream"
  | Oversized_payload -> "oversized_payload"
;;

type provider_failure_kind =
  | Capacity_exhausted of
      { scope : provider_failure_scope
      ; retry_after : float option
      ; model : string option
      }
  | Hard_quota of { retry_after : float option }
  | Capability_mismatch of { capability : string option }
  | Cli_policy_invalid of
      { tool_name : string option
      ; rule : int option
      }
  | Cli_startup_failed of { reason : cli_startup_failure_reason }
  | Provider_parse_error of { parser : string option }
  | Provider_wire_error of
      { format : provider_wire_format
      ; kind : provider_wire_error_kind
      }
  | Provider_reported_error of { error_type : string option }
  | Provider_interrupted
  | Response_body_too_large of { limit_bytes : int }
  (* agent-core boundary: the provider returned a 200 with no deliverable content (no
     thinking, text, or tool_calls). Distinct from a parse error. Preserve the
     typed stop reason so policy remains outside this transport fact. *)
  | Empty_completion of { stop_reason : Types.stop_reason }
  (* agent-core boundary: provider-reported context-window overflow (e.g. glm 1261),
     kept typed so consumers reach their compaction/shrink path instead of
     seeing a generic invalid-request. *)
  | Context_overflow of { limit : int option }
  | Unknown_provider_failure of { reason : string option }

type refusal_body =
  | Received of string
  | Not_received_in_window

let refusal_body_text = function
  | Received body -> body
  | Not_received_in_window -> ""

type http_error =
  | HttpError of
      { code : int
      ; body : refusal_body
      ; retry_after_header : float option
      }
  | NetworkError of
      { message : string
      ; kind : network_error_kind
      }
  | TimeoutError of
      { message : string
      ; phase : timeout_phase
      }
  | AcceptRejected of { reason : string }
  (* Signals that a provider kind requires a non-HTTP transport (e.g. a
     CLI subprocess transport for
     [Claude_code]/[Codex]/[Gemini]/[Kimi])
     but the caller did not wire one.  Distinct from [NetworkError] so
     callers can skip the candidate without counting it as a flaky
     network failure, and so callers see a clear "configuration/wiring
     bug" rather than a cohttp [Unknown scheme None]. *)
  | ProviderTerminal of
      { kind : provider_terminal_kind
      ; message : string
      }
  | ProviderFailure of
      { kind : provider_failure_kind
      ; message : string
      }

(* ── Internal helpers ──────────────────────────────────────── *)

let provider_failure_scope_to_string = function
  | Failure_scope_model -> "model"
  | Failure_scope_account -> "account"
  | Failure_scope_region -> "region"
  | Failure_scope_provider -> "provider"
  | Failure_scope_unknown -> "unknown"
;;

let provider_failure_kind_to_string = function
  | Capacity_exhausted { scope; _ } ->
    Printf.sprintf "capacity_exhausted:%s" (provider_failure_scope_to_string scope)
  | Hard_quota _ -> "hard_quota"
  | Capability_mismatch { capability = Some capability } ->
    Printf.sprintf "capability_mismatch:%s" capability
  | Capability_mismatch { capability = None } -> "capability_mismatch"
  | Cli_policy_invalid { tool_name = Some tool_name; rule = Some rule } ->
    Printf.sprintf "cli_policy_invalid:rule_%d:%s" rule tool_name
  | Cli_policy_invalid { tool_name = Some tool_name; rule = None } ->
    Printf.sprintf "cli_policy_invalid:%s" tool_name
  | Cli_policy_invalid { tool_name = None; rule = Some rule } ->
    Printf.sprintf "cli_policy_invalid:rule_%d" rule
  | Cli_policy_invalid { tool_name = None; rule = None } -> "cli_policy_invalid"
  | Cli_startup_failed { reason } ->
    Printf.sprintf "cli_startup_failed:%s" (cli_startup_failure_reason_to_string reason)
  | Provider_parse_error { parser = Some parser } ->
    Printf.sprintf "provider_parse_error:%s" parser
  | Provider_parse_error { parser = None } -> "provider_parse_error"
  | Provider_wire_error { format; kind } ->
    Printf.sprintf
      "provider_wire_error:%s:%s"
      (provider_wire_format_to_string format)
      (provider_wire_error_kind_to_string kind)
  | Provider_reported_error { error_type = Some error_type } ->
    Printf.sprintf "provider_reported_error:%s" error_type
  | Provider_reported_error { error_type = None } -> "provider_reported_error"
  | Provider_interrupted -> "provider_interrupted"
  | Response_body_too_large { limit_bytes } ->
    Printf.sprintf "response_body_too_large:%d" limit_bytes
  | Empty_completion { stop_reason } ->
    Printf.sprintf "empty_completion:%s" (Types.stop_reason_to_string stop_reason)
  | Context_overflow { limit = Some limit } ->
    Printf.sprintf "context_overflow:limit_%d" limit
  | Context_overflow { limit = None } -> "context_overflow"
  | Unknown_provider_failure { reason = Some reason } ->
    Printf.sprintf "unknown_provider_failure:%s" reason
  | Unknown_provider_failure { reason = None } -> "unknown_provider_failure"
;;

let provider_failure_to_string ~kind ~message =
  let name = provider_failure_kind_to_string kind in
  if String.trim message = "" then name else Printf.sprintf "%s: %s" name message
;;

let empty_completion_error ~stop_reason =
  ProviderFailure
    { kind = Empty_completion { stop_reason }
    ; message =
        "provider returned an empty assistant turn (no thinking, text, or tool calls)"
    }
;;


let stream_production_to_label = function
  | Streaming_answer -> "streaming_answer"
  | Streaming_thinking -> "streaming_thinking"
  | Streaming_tool_call -> "streaming_tool_call"
  | Streaming_heartbeat -> "streaming_heartbeat"
  | Streaming_substrate -> "streaming_substrate"
  | Streaming_done -> "streaming_done"
  | Streaming_unknown -> "streaming_unknown"
;;

let stream_idle_state_to_label = function
  | Awaiting_first_event -> "awaiting_first_event"
  | Awaiting_first_delta -> "awaiting_first_delta"
  | Producing production -> stream_production_to_label production
;;

let timeout_phase_to_label = function
  | Queue -> "queue"
  | First_token -> "first_token"
  | Wall_clock -> "wall_clock"
  | Capacity_backpressure -> "capacity_backpressure"
  | Http_operation -> "http_operation"
  | Non_streaming_body -> "non_streaming_body"
  | Stream_body -> "stream_body"
  | Stream_idle state ->
    Printf.sprintf "stream_idle:%s" (stream_production_to_label state)
  | Provider_step -> "provider_step"
  | Cli_stdout_idle -> "cli_stdout_idle"
  | Unknown_timeout -> "unknown_timeout"
;;

type 'clock explicit_deadline =
  | Unbounded
  | Bounded of 'clock * float

let resolve_explicit_deadline ~operation ~parameter ~clock ~timeout_s =
  match timeout_s with
  | None -> Ok Unbounded
  | Some seconds when (not (Float.is_finite seconds)) || Float.compare seconds 0.0 <= 0 ->
    Error
      (AcceptRejected
         { reason =
             Printf.sprintf
               "%s: %s must be finite and greater than zero, got %.17g"
               operation
               parameter
               seconds
         })
  | Some seconds ->
    (match clock with
     | Some clock -> Ok (Bounded (clock, seconds))
     | None ->
       Error
         (AcceptRejected
            { reason =
                Printf.sprintf
                  "%s: %s was supplied without the clock required to enforce it"
                  operation
                  parameter
            }))
;;

let with_explicit_deadline deadline f =
  match deadline with
  | Unbounded -> f ()
  | Bounded (clock, timeout_s) ->
    (match Under_deadline.run clock timeout_s f with
     | Ok answer -> answer
     | Error `Timeout -> raise Eio.Time.Timeout)
;;

let%test "explicit deadline: clock alone remains unbounded" =
  match
    resolve_explicit_deadline
      ~operation:"test"
      ~parameter:"timeout_s"
      ~clock:(Some ())
      ~timeout_s:None
  with
  | Ok Unbounded -> true
  | Ok (Bounded _) | Error _ -> false
;;

let%test "explicit deadline: timeout without clock is rejected" =
  match
    resolve_explicit_deadline
      ~operation:"test"
      ~parameter:"timeout_s"
      ~clock:None
      ~timeout_s:(Some 1.0)
  with
  | Error (AcceptRejected _) -> true
  | Ok _
  | Error
      ( HttpError _
      | NetworkError _
      | TimeoutError _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

(* ── Exception → network_error_kind classification ───────── *)

let classify_unix_error = function
  | Unix.ECONNREFUSED -> Connection_refused
  | Unix.ECONNRESET -> Connection_reset
  | Unix.EPIPE -> End_of_file
  | Unix.ETIMEDOUT -> Timeout
  | Unix.ENETUNREACH -> Dns_failure
  | Unix.EHOSTUNREACH -> Dns_failure
  | Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS -> Local_resource_exhaustion
  | Unix.EADDRNOTAVAIL -> Local_resource_exhaustion
  | (Unix.E2BIG | Unix.EACCES | Unix.EAGAIN | Unix.EBADF | Unix.EBUSY | Unix.ECHILD | Unix.EDEADLK | Unix.EDOM | Unix.EEXIST | Unix.EFAULT | Unix.EFBIG | Unix.EINTR | Unix.EINVAL | Unix.EIO | Unix.EISDIR | Unix.EMLINK | Unix.ENAMETOOLONG | Unix.ENODEV | Unix.ENOENT | Unix.ENOEXEC | Unix.ENOLCK | Unix.ENOMEM | Unix.ENOSPC | Unix.ENOSYS | Unix.ENOTDIR | Unix.ENOTEMPTY | Unix.ENOTTY | Unix.ENXIO | Unix.EPERM | Unix.ERANGE | Unix.EROFS | Unix.ESPIPE | Unix.ESRCH | Unix.EXDEV | Unix.EWOULDBLOCK | Unix.EINPROGRESS | Unix.EALREADY | Unix.ENOTSOCK | Unix.EDESTADDRREQ | Unix.EMSGSIZE | Unix.EPROTOTYPE | Unix.ENOPROTOOPT | Unix.EPROTONOSUPPORT | Unix.ESOCKTNOSUPPORT | Unix.EOPNOTSUPP | Unix.EPFNOSUPPORT | Unix.EAFNOSUPPORT | Unix.EADDRINUSE | Unix.ENETDOWN | Unix.ENETRESET | Unix.ECONNABORTED | Unix.EISCONN | Unix.ENOTCONN | Unix.ESHUTDOWN | Unix.ETOOMANYREFS | Unix.EHOSTDOWN | Unix.ELOOP | Unix.EOVERFLOW | Unix.EUNKNOWNERR _) as unclassified_unix_error -> let (_ : Unix.error) = unclassified_unix_error in
    Unknown
;;

let network_error_kind_to_string = function
  | Connection_refused -> "connection_refused"
  | Dns_failure -> "dns_failure"
  | Tls_error -> "tls_error"
  | Timeout -> "timeout"
  | Local_resource_exhaustion -> "local_resource_exhaustion"
  | Connection_reset -> "connection_reset"
  | End_of_file -> "end_of_file"
  | Unknown -> "unknown"
;;

let network_error_kind_of_string = function
  | "connection_refused" -> Some Connection_refused
  | "dns_failure" -> Some Dns_failure
  | "tls_error" -> Some Tls_error
  | "timeout" -> Some Timeout
  | "local_resource_exhaustion" -> Some Local_resource_exhaustion
  | "connection_reset" -> Some Connection_reset
  | "end_of_file" -> Some End_of_file
  | "unknown" -> Some Unknown
  | _ -> None
;;

let%test "network_error_kind: every kind reads back from its own spelling" =
  (* A new kind stops the build at this exhaustive match. Add it to
     [every_kind] in the same edit, so the round trip covers it. *)
  let (_ : network_error_kind -> unit) = function
    | Connection_refused
    | Dns_failure
    | Tls_error
    | Timeout
    | Local_resource_exhaustion
    | Connection_reset
    | End_of_file
    | Unknown -> ()
  in
  let every_kind =
    [ Connection_refused
    ; Dns_failure
    ; Tls_error
    ; Timeout
    ; Local_resource_exhaustion
    ; Connection_reset
    ; End_of_file
    ; Unknown
    ]
  in
  List.for_all
    (fun kind ->
       network_error_kind_of_string (network_error_kind_to_string kind) = Some kind)
    every_kind
;;

let%test "network_error_kind: a spelling no kind emits reads as None" =
  network_error_kind_of_string "connection_refused_or_reset" = None
;;

type http_scheme =
  | Http
  | Https

type validated_uri =
  { uri : Uri.t
  ; url : string
  ; scheme : http_scheme
  ; host : string
  ; port : int
  }

let http_scheme_to_string = function
  | Http -> "http"
  | Https -> "https"
;;

let invalid_url url detail =
  Error
    (NetworkError
       { message = Printf.sprintf "invalid URL %S: %s" url detail; kind = Unknown })
;;

let parse_uri url =
  match Uri.of_string url with
  | exception Invalid_argument detail -> invalid_url url detail
  | uri ->
    let* scheme =
      match Option.map String.lowercase_ascii (Uri.scheme uri) with
      | Some "http" -> Ok Http
      | Some "https" -> Ok Https
      | Some unsupported ->
        invalid_url url (Printf.sprintf "unsupported scheme %S" unsupported)
      | None -> invalid_url url "missing HTTP scheme"
    in
    let* host =
      match Uri.host uri with
      | Some host when String.trim host <> "" -> Ok host
      | Some _ | None -> invalid_url url "missing host"
    in
    let* port =
      match Uri.port uri with
      | Some port when port > 0 && port <= 65535 -> Ok port
      | Some port -> invalid_url url (Printf.sprintf "invalid port %d" port)
      | None ->
        Ok
          (match scheme with
           | Http -> 80
           | Https -> 443)
    in
    Ok { uri; url; scheme; host; port }
;;

let known_network_error_kind = function
  | Unknown -> None
  | ( Connection_refused
    | Dns_failure
    | Tls_error
    | Timeout
    | Local_resource_exhaustion
    | Connection_reset
    | End_of_file ) as kind -> Some kind
;;

(* For composite errors, prefer kinds that should not be retried (local
   resource exhaustion and TLS errors) over transient network failures.
   This mirrors the severity ordering rather than the retry policy itself. *)
let network_error_kind_is_non_retryable = function
  | Local_resource_exhaustion | Tls_error -> true
  | Connection_refused | Dns_failure | Timeout | Connection_reset | End_of_file | Unknown ->
    false
;;

let classify_eio_backend_error = function
  | Eio_unix.Unix_error (code, _, _) -> Some (classify_unix_error code)
  | _ -> None
;;

let rec classify_eio_error = function
  | Eio.Net.E net_error ->
    (match net_error with
     | Eio.Net.Connection_failure (Eio.Net.Refused _) -> Connection_refused
     | Eio.Net.Connection_failure Eio.Net.No_matching_addresses -> Dns_failure
     | Eio.Net.Connection_failure Eio.Net.Timeout -> Timeout
     | Eio.Net.Connection_reset backend ->
       Option.value (classify_eio_backend_error backend) ~default:End_of_file)
  | Eio.Exn.X backend ->
    Option.value (classify_eio_backend_error backend) ~default:Unknown
  | Eio.Exn.Multiple_io errors ->
    let kinds =
      List.filter_map
        (fun (err, _, _) -> classify_eio_error err |> known_network_error_kind)
        errors
    in
    (match List.find_opt network_error_kind_is_non_retryable kinds with
     | Some kind -> kind
     | None ->
       (match kinds with
        | kind :: _ -> kind
        | [] -> Unknown))
  | _ -> Unknown
;;

let network_error_of_eio err exn =
  NetworkError { message = Printexc.to_string exn; kind = classify_eio_error err }
;;

let unknown_network_error msg = NetworkError { message = msg; kind = Unknown }

let https_init_error_network_kind = function
  | Api_common.Ca_certs_unavailable _ -> Tls_error
  | Api_common.Tls_config_unavailable _ -> Tls_error
;;

(** Classify a network/timeout exception into an [http_error]. A timeout
    is classified as [Http_operation] — accurate for the connect/headers
    phase; body-phase timeouts are intercepted before this function (see
    {!with_post_stream}) so the caller can attach a phase-accurate label. *)
let classify_network_exn (e : exn) =
  match e with
  | End_of_file -> Some (NetworkError { message = "End_of_file"; kind = End_of_file })
  | Eio.Time.Timeout ->
    Some
      (TimeoutError
         { message = "HTTP operation exceeded wall-clock timeout"
         ; phase = Http_operation
         })
  | Unix.Unix_error (code, _, _) as exn ->
    Some
      (NetworkError { message = Printexc.to_string exn; kind = classify_unix_error code })
  | Eio.Io (err, _) as exn -> Some (network_error_of_eio err exn)
  | (Tls_eio.Tls_alert _ | Tls_eio.Tls_failure _) as exn ->
    Some (NetworkError { message = Printexc.to_string exn; kind = Tls_error })
  | Sys_error _ | Failure _ -> None
  | _ -> None
;;

let catch_network f =
  try f () with
  | exn ->
    (match classify_network_exn exn with
     | Some e -> Error e
     | None -> raise exn)
;;

(* ── classify_network_exn / phase-mapping invariants ─────────── *)

let%test "classify_network_exn: Eio.Time.Timeout is Http_operation" =
  (* A timeout classified HERE is a connect/headers-phase timeout
     ([catch_network] wraps only that phase in with_post_stream). Body-phase
     timeouts are intercepted before this point, so this stays accurate. *)
  match classify_network_exn Eio.Time.Timeout with
  | Some (TimeoutError { phase = Http_operation; _ }) -> true
  | Some (TimeoutError { phase = (Queue | (First_token | (Wall_clock | (Capacity_backpressure | (Non_streaming_body | (Stream_body | (Provider_step | (Cli_stdout_idle | (Unknown_timeout | Stream_idle _)))))))));_})
  | Some (HttpError _ | (NetworkError _ | (AcceptRejected _ | (ProviderTerminal _ | ProviderFailure _))))
  | None -> false
;;

let%test "classify_network_exn: non-network exn is None (propagates)" =
  classify_network_exn Not_found = None
;;

(* ── Retry-After response header ────────── *)

(* [Http.Header.get] is case-insensitive per cohttp's contract (mirrors the
   "server"/"cf-ray" lookups in [Http_client_diagnostics.profile_opaque_client_error]). *)
let retry_after_header_of_response_headers resp_headers =
  match Http.Header.get resp_headers "retry-after" with
  | None -> None
  | Some raw -> Http_retry_after.parse_seconds ~now:(Unix.gettimeofday ()) raw
;;

let content_type_of_response_headers resp_headers =
  match Http.Header.get resp_headers "content-type" with
  | None -> None
  | Some raw ->
    (match String.trim raw with
     | "" -> None
     | trimmed -> Some trimmed)
;;

(* ── Public API ────────────────────────────────────────────── *)

type one_dispatch_phase =
  | Before_dispatch
  | Dispatch_started
  | Response_received

type response_header_evidence = Response_header_evidence of string

let response_header_evidence_fingerprint (Response_header_evidence fingerprint) =
  fingerprint
;;

let normalize_response_headers headers =
  headers
  |> List.map (fun (name, value) ->
    String.lowercase_ascii (String.trim name), String.trim value)
  |> List.sort (fun (left_name, left_value) (right_name, right_value) ->
    match String.compare left_name right_name with
    | 0 -> String.compare left_value right_value
    | order -> order)
;;

let response_header_name_is_sensitive = function
  | "authorization"
  | "proxy-authorization"
  | "cookie"
  | "set-cookie"
  | "www-authenticate"
  | "proxy-authenticate"
  | "authentication-info"
  | "proxy-authentication-info"
  | "api-key"
  | "x-api-key" -> true
  | _ -> false
;;

let capture_response_header_evidence headers =
  let raw_headers = Http.Header.to_list headers in
  let retry_after_header =
    match
      List.filter
        (fun (name, _) ->
           String.equal (String.lowercase_ascii (String.trim name)) "retry-after")
        raw_headers
    with
    | [ (_, value) ] ->
      Http.Header.of_list [ "retry-after", value ]
      |> retry_after_header_of_response_headers
    | [] | _ :: _ :: _ -> None
  in
  let redacted_headers =
    raw_headers
    |> normalize_response_headers
    |> List.map (fun (name, value) ->
      if response_header_name_is_sensitive name then name, "[REDACTED]" else name, value)
  in
  let fingerprint =
    `Assoc
      [ "version", `Int 1
      ; ( "headers"
        , `List
            (List.map
               (fun (name, value) -> `List [ `String name; `String value ])
               redacted_headers) )
      ]
    |> Yojson.Safe.to_string
    |> Agent_core_sha256.digest_string
    |> Agent_core_sha256.to_hex
  in
  Response_header_evidence fingerprint, retry_after_header
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] header_evidence_fingerprint_for_test headers =
  headers
  |> Http.Header.of_list
  |> capture_response_header_evidence
  |> fst
  |> response_header_evidence_fingerprint
;;

let%test "response header evidence is canonical, multiplicity-sensitive, and redacted" =
  let first =
    header_evidence_fingerprint_for_test [ "X-Trace-B", " beta "; "X-Trace-A", "alpha" ]
  in
  let reordered =
    header_evidence_fingerprint_for_test [ "x-trace-a", "alpha"; "x-trace-b", "beta" ]
  in
  let one = header_evidence_fingerprint_for_test [ "x-trace", "same" ] in
  let duplicate =
    header_evidence_fingerprint_for_test [ "x-trace", "same"; "X-Trace", "same" ]
  in
  let secret_one =
    header_evidence_fingerprint_for_test [ "set-cookie", "session=secret-one" ]
  in
  let secret_two =
    header_evidence_fingerprint_for_test [ "Set-Cookie", "session=secret-two" ]
  in
  String.equal first reordered
  && (not (String.equal one duplicate))
  && String.equal secret_one secret_two
;;

type raw_sync_response =
  { status : int
  ; body : string
  ; retry_after_header : float option
  ; content_type : string option
  }

type validated_sync_request =
  { origin : validated_uri
  ; header : Http.Header.t
  ; body : string
  }

type sync_transport_receipt =
  { response : raw_sync_response
  ; body_receipt : refusal_body
  ; response_header_evidence : response_header_evidence
  }

let prepare_sync_request ~url ~headers ~body =
  let* origin = parse_uri url in
  let* header =
    try Ok (Http.Header.of_list headers) with
    | Invalid_argument reason -> Error (AcceptRejected { reason })
  in
  Ok { origin; header; body }
;;

let%test "prepare_sync_request rejects missing host before dispatch" =
  match prepare_sync_request ~url:"http:///v1/messages" ~headers:[] ~body:"{}" with
  | Error (NetworkError { kind = Unknown; _ }) -> true
  | Ok _
  | Error
      ( HttpError _
      | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file )
          }
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

let%test "prepare_sync_request rejects unsupported schemes before dispatch" =
  match prepare_sync_request ~url:"ftp://example.com/v1" ~headers:[] ~body:"{}" with
  | Error (NetworkError { kind = Unknown; _ }) -> true
  | Ok _
  | Error
      ( HttpError _
      | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file )
          }
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

let%test "Retry-After is captured once with explicit duplicate ambiguity" =
  let capture headers =
    headers |> Http.Header.of_list |> capture_response_header_evidence |> snd
  in
  let retry_after_header = capture [ "Retry-After", "7" ] in
  let response =
    { status = 429; body = "rate limited"; retry_after_header; content_type = None }
  in
  let duplicate = capture [ "Retry-After", "7"; "retry-after", "8" ] in
  response.retry_after_header = Some 7.0
  && response.retry_after_header = retry_after_header
  && duplicate = None
;;

type post_sync_once_error =
  | Before_dispatch_error of http_error
  | Dispatch_started_error of http_error
  | Response_received_error of
      { status : int
      ; error : http_error
      }

type connection = Http_client_cache.connection

let add_connection_close headers = ("connection", "close") :: headers

let maybe_add_connection_close ?cache headers =
  match cache with
  | Some _ -> headers
  | None -> add_connection_close headers
;;

(* ── Connection cache ──────────────────────────────────────── *)

(* [tls_config] belongs to the cache because a parked connection was verified
   under it: a request that leased the connection under another trust
   configuration would skip that configuration's check. *)
type cache =
  { pool : Http_client_cache.t
  ; tls_config : Tls.Config.client option
  }

type cache_close_counts = Http_client_cache.close_counts =
  { request_failed : int
  ; request_not_delivered : int
  ; not_persistent : int
  ; body_not_drained : int
  ; transport_ended : int
  }

type cache_stats = Http_client_cache.stats =
  { idle_per_host : (string * int) list
  ; total_idle : int
  ; reuse_count_total : int
  ; create_count_total : int
  ; closed_total : cache_close_counts
  ; closed_after_reuse : cache_close_counts
  }

let create_cache ~sw ~mono_clock ?max_idle_per_host ?idle_ttl_seconds ?tls_config () =
  { pool =
      Http_client_cache.create ~sw ~mono_clock ?max_idle_per_host ?idle_ttl_seconds ()
  ; tls_config
  }
;;

let cache_stats cache = Http_client_cache.stats cache.pool

let cache_key_of_origin (origin : validated_uri) : Http_client_cache.Key.t =
  { Http_client_cache.Key.scheme = http_scheme_to_string origin.scheme
  ; host = origin.host
  ; port = origin.port
  }
;;

let%test "cache_key_of_origin resolves https port 443 once" =
  match parse_uri "https://example.com/path" with
  | Ok origin ->
    cache_key_of_origin origin
    = { Http_client_cache.Key.scheme = "https"; host = "example.com"; port = 443 }
  | Error _ -> false
;;

let%test "cache_key_of_origin resolves http port 80 once" =
  match parse_uri "http://example.com/path" with
  | Ok origin ->
    cache_key_of_origin origin
    = { Http_client_cache.Key.scheme = "http"; host = "example.com"; port = 80 }
  | Error _ -> false
;;

let%test "cache_key_of_origin preserves explicit port" =
  match parse_uri "https://example.com:8443/path" with
  | Ok origin -> (cache_key_of_origin origin).Http_client_cache.Key.port = 8443
  | Error _ -> false
;;

(** Resolve [origin] and prepare the TLS wrapper if needed.
    The result is reused by both one-shot clients and cached connections. *)
let resolve_origin ?tls_config net (origin : validated_uri) =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t) in
  let service = Int.to_string origin.port in
  let* addresses =
    try
      match Eio.Net.getaddrinfo_stream ~service net origin.host with
      | (_ :: _ as addresses) -> Ok addresses
      | [] ->
        Error
          (NetworkError
             { message = Printf.sprintf "failed to resolve hostname: %s" origin.host
             ; kind = Dns_failure
             })
    with
    | Eio.Io (err, _) as exn -> Error (network_error_of_eio err exn)
    | Unix.Unix_error (code, _, _) as exn ->
      Error
        (NetworkError
           { message = Printexc.to_string exn; kind = classify_unix_error code })
    | Failure msg -> Error (unknown_network_error msg)
  and* tls_wrap =
    match origin.scheme with
    | Https ->
      let wrap_error reason =
        NetworkError
          { message =
              Printf.sprintf
                "HTTPS requested but TLS not available for %s: %s"
                origin.url
                (Api_common.https_init_error_to_string reason)
          ; kind = https_init_error_network_kind reason
          }
      in
      let* wrap =
        Result.map_error wrap_error (Api_common.make_https_result ?tls_config ())
      in
      let+ peer =
        Result.map_error
          (fun reason ->
             NetworkError
               { message =
                   Printf.sprintf
                     "https host %S of %s is neither an address nor a host name; the \
                      certificate cannot be checked against it: %s"
                     origin.host
                     origin.url
                     reason
               ; kind = Tls_error
               })
          (Api_common.tls_peer_of_host origin.host)
      in
      Some (wrap peer)
    | Http -> Ok None
  in
  Ok (net, addresses, tls_wrap)
;;

(** Create a single transport connection bound to [sw]. This is the unit
    stored in the connection cache and reused across requests. *)
let make_connection ?tls_config ~sw ~net ~origin () : (connection, http_error) result =
  let* net, addresses, tls_wrap = resolve_origin ?tls_config net origin in
  try
    let sock = Tcp_address_race.connect ~sw ~net addresses in
    let conn : connection =
      try
        match tls_wrap with
        | Some wrap -> (wrap sock :> connection)
        | None -> (sock :> connection)
      with exn ->
        let bt = Printexc.get_raw_backtrace () in
        Eio.Resource.close sock;
        Printexc.raise_with_backtrace exn bt
    in
    Diag.debug "http_client" "make_connection: new connection for %s" origin.url;
    Ok conn
  with
  | Eio.Io (err, _) as exn -> Error (network_error_of_eio err exn)
  | Unix.Unix_error (code, _, _) as exn ->
    Error
      (NetworkError { message = Printexc.to_string exn; kind = classify_unix_error code })
  | Failure msg -> Error (unknown_network_error msg)
;;

(* True when the transport itself named the peer's close: an errno that
   [classify_unix_error] sends to [Connection_reset] or [End_of_file]. The
   default [classify_eio_error] gives a reset whose backend error is not an
   errno (tls-eio's [Tls_socket_closed], which tls_eio.mli does not export) is
   a guess. A guess does not count: [Request_wire.Not_delivered] is the fact
   that later lets a request be sent again (RFC-0492 §3.3 condition 2). *)
let backend_named_peer_close backend =
  match classify_eio_backend_error backend with
  | Some (Connection_reset | End_of_file) -> true
  | Some
      ( Connection_refused
      | Dns_failure
      | Tls_error
      | Timeout
      | Local_resource_exhaustion
      | Unknown )
  | None -> false
;;

let transport_named_peer_close = function
  | Unix.Unix_error (code, _, _) ->
    (match classify_unix_error code with
     | Connection_reset | End_of_file -> true
     | Connection_refused
     | Dns_failure
     | Tls_error
     | Timeout
     | Local_resource_exhaustion
     | Unknown -> false)
  | Eio.Io (Eio.Net.E net_error, _) ->
    (match net_error with
     | Eio.Net.Connection_reset backend -> backend_named_peer_close backend
     | Eio.Net.Connection_failure _ -> false)
  | Eio.Io (Eio.Exn.X backend, _) -> backend_named_peer_close backend
  | _ -> false
;;

(* The reason a request that failed before it had an answer ends its
   connection. A request is [Request_not_delivered] only on the evidence of
   [Request_wire.delivery]; every other failure may have reached the server. *)
let failure_close_reason wire : Reuse_verdict.close_reason =
  match Request_wire.delivery ~names_peer_close:transport_named_peer_close wire with
  | Request_wire.Not_delivered -> Request_not_delivered
  | Request_wire.Possibly_delivered -> Request_failed
;;

(* A provider request body is megabytes of JSON. cohttp-eio copies it into the
   connection's write buffer in one go, and the buffer's flusher then hands
   everything that accumulated to one write, which TLS encrypts without
   suspending: one request held its domain for the whole encryption (64-125 ms
   at a time on a live server). A write is passed down this many bytes at a
   time, and the flusher yields between slices so the other fibers on the
   domain run. The bytes on the wire and their order are unchanged.

   The slicing sits in the flusher, not in the body source. cohttp-eio closes
   the write buffer as soon as it has read the response head, and the fiber
   copying the body would then write to a closed buffer if it had suspended
   mid-copy. The flusher drains what is buffered after the close. *)
let request_slice_bytes = 65_536

(* The leading [limit] bytes of [buffers]; [limit] is positive. *)
let rec leading_bytes limit = function
  | [] -> []
  | buffer :: rest ->
    let length = Cstruct.length buffer in
    if length >= limit
    then [ Cstruct.sub buffer 0 limit ]
    else buffer :: leading_bytes (limit - length) rest
;;

(* A connection's bytes from its final response on.

   A server may send interim 1xx responses before the final one, and a client
   has to read past them (RFC 9110 §15.2). cohttp-eio hands back the first
   response head it reads and drops the buffer the rest arrived in, so the
   final response cannot be read after it. The interim heads are taken off
   here, below cohttp-eio. cohttp's own response reader parses each head. A
   1xx head ends at its header section and carries no content, so it is
   dropped whole, and everything from the first other head on is passed up
   unchanged. 101 (Switching Protocols) is the last HTTP message on its
   connection, so it is passed up as the answer.

   The reader buffers ahead of the head it parses. [read_to_final_head] keeps
   every byte the reader pulled, so the bytes from the final head on are
   passed up before the connection is read again. *)
module Final_response_bytes = struct
  module Response_io = Cohttp.Response.Private.Make (Cohttp_eio.Private.IO)

  type state =
    | Before_final_head
    | From_final_head of Cstruct.t (* read from the connection, not yet passed up *)

  type t =
    { read : Cstruct.t -> int
    ; mutable state : state
    }

  let create read = { read; state = Before_final_head }

  let is_interim response =
    match Http.Response.status response with
    | `Switching_protocols -> false
    | status ->
      let code = Http.Status.to_int status in
      code >= 100 && code < 200
  ;;

  (* A final head that is cut short, and bytes that are not HTTP, are passed
     up as they arrived: cohttp-eio reads them again and reports them as it
     did before. After an interim head that is cut short nothing is left to
     pass up, and cohttp-eio meets the end of file. *)
  let read_to_final_head read =
    let pulled = Buffer.create 0 in
    let module Pulled = struct
      type t = unit

      let read_methods = []

      let single_read () buffer =
        let count = read buffer in
        Buffer.add_string pulled (Cstruct.to_string ~len:count buffer);
        count
      ;;
    end
    in
    let source = Eio.Resource.T ((), Eio.Flow.Pi.source (module Pulled)) in
    (* No size limit, as where cohttp-eio reads a head. *)
    let input = Eio.Buf_read.of_flow ~max_size:max_int source in
    let rec final_head_offset () =
      let offset = Eio.Buf_read.consumed_bytes input in
      match Response_io.read input with
      | `Ok response when is_interim response -> final_head_offset ()
      | `Ok _ | `Eof | `Invalid _ -> offset
    in
    let offset = final_head_offset () in
    Cstruct.of_string ~off:offset (Buffer.contents pulled)
  ;;

  let single_read t buffer =
    let pulled =
      match t.state with
      | Before_final_head -> read_to_final_head t.read
      | From_final_head pulled -> pulled
    in
    if Cstruct.is_empty pulled
    then (
      t.state <- From_final_head pulled;
      t.read buffer)
    else (
      let count = min (Cstruct.length pulled) (Cstruct.length buffer) in
      Cstruct.blit pulled 0 buffer 0 count;
      t.state <- From_final_head (Cstruct.shift pulled count);
      count)
  ;;
end

(* Everything [Final_response_bytes] passes up when the connection delivers
   [arrivals] one read at a time and then ends. *)
let passed_up_from arrivals =
  let arrivals = ref arrivals in
  let read buffer =
    match !arrivals with
    | [] -> raise End_of_file
    | arrival :: rest ->
      arrivals := rest;
      Cstruct.blit_from_string arrival 0 buffer 0 (String.length arrival);
      String.length arrival
  in
  let final_response = Final_response_bytes.create read in
  let passed_up = Buffer.create 0 in
  let buffer = Cstruct.create 4096 in
  let rec drain () =
    let count = Final_response_bytes.single_read final_response buffer in
    Buffer.add_string passed_up (Cstruct.to_string ~len:count buffer);
    drain ()
  in
  try drain () with
  | End_of_file -> Buffer.contents passed_up
;;

let%test "interim heads are dropped wherever the connection splits its bytes" =
  let final = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" in
  let interim =
    "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n"
  in
  let wire = interim ^ final in
  let split_at position =
    [ String.sub wire 0 position
    ; String.sub wire position (String.length wire - position)
    ]
  in
  List.for_all
    (fun position -> String.equal (passed_up_from (split_at position)) final)
    (List.init (String.length wire - 1) (fun index -> index + 1))
  && String.equal (passed_up_from [ interim; final ]) final
  && String.equal (passed_up_from [ wire ]) final
;;

let%test "a response that is not interim is passed up as it arrived" =
  let unchanged wire = String.equal (passed_up_from [ wire ]) wire in
  unchanged "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
  && unchanged "HTTP/1.1 200 OK\r\n\r\nHTTP/1.1 103 Early Hints\r\n\r\n"
  && unchanged "HTTP/1.1 200 OK\r\nContent-Le"
  && unchanged "not http"
  && String.equal (passed_up_from [ "HTTP/1.1 103 Early Hints\r\nLink: <" ]) ""
  && String.equal (passed_up_from []) ""
;;

let track_connection ~wire connection =
  let eof_seen = Request_wire.eof_seen wire in
  let module Flow = struct
    type t = unit

    (* Expose no alternate read path: every transport read must pass through
       [transport_read] below so raw EOF cannot bypass the observation. *)
    let read_methods = []

    let transport_read buffer =
      match Eio.Flow.single_read connection buffer with
      | count ->
        Request_wire.bytes_read wire count;
        count
      | exception End_of_file ->
        eof_seen := true;
        raise End_of_file
    ;;

    let final_response = Final_response_bytes.create transport_read
    let single_read () buffer = Final_response_bytes.single_read final_response buffer

    (* Every write passes through here so an error a write raises is seen
       where it is raised, not guessed from the exception that finally
       escapes (tls-eio stores an error from one side and raises it again on
       the other). Cancellation is not a write failure. *)
    let observed_write write =
      Request_wire.write_began wire;
      try write () with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        let backtrace = Printexc.get_raw_backtrace () in
        Request_wire.write_raised wire exn;
        Printexc.raise_with_backtrace exn backtrace
    ;;

    (* The previous call left part of its batch unwritten, so this call
       continues it. The yield comes before the write: a cancellation there
       leaves this call with nothing written. *)
    let batch_continues = ref false

    let single_write () buffers =
      if !batch_continues then Eio.Fiber.yield ();
      let slice = leading_bytes request_slice_bytes buffers in
      let written =
        observed_write (fun () -> Eio.Flow.single_write connection slice)
      in
      batch_continues := written < Cstruct.lenv buffers;
      written
    ;;

    let copy () ~src = observed_write (fun () -> Eio.Flow.copy src connection)
    let shutdown () command = Eio.Flow.shutdown connection command
  end
  in
  let operations =
    Eio.Resource.handler
      (Eio.Resource.H (Eio.Resource.Close, fun () -> Eio.Resource.close connection)
       :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Flow)))
  in
  Eio.Resource.T ((), operations)
;;


let%test "a large write reaches the connection in slices with a yield between them" =
  Eio_main.run
  @@ fun _env ->
  (* A fiber that only yields takes one turn each time the fiber beside it
     yields, so its turn count is the other fiber's yield count. *)
  let turns_beside work =
    let finished = ref false in
    let turns = ref 0 in
    Eio.Fiber.both
      (fun () ->
         work ();
         finished := true)
      (fun () ->
         while not !finished do
           incr turns;
           Eio.Fiber.yield ()
         done);
    !turns in
  let writes = ref [] in
  let received = Buffer.create 0 in
  let module Peer = struct
    type t = unit

    let read_methods = []
    let single_read () _ = raise End_of_file

    let single_write () buffers =
      writes := Cstruct.lenv buffers :: !writes;
      List.iter
        (fun buffer -> Buffer.add_string received (Cstruct.to_string buffer))
        buffers;
      Cstruct.lenv buffers
    ;;

    let copy () ~src = Eio.Flow.Pi.simple_copy ~single_write () ~src
    let shutdown () _ = ()
  end
  in
  let connection : connection =
    Eio.Resource.T
      ( ()
      , Eio.Resource.handler
          (Eio.Resource.H (Eio.Resource.Close, fun () -> ())
           :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Peer))) )
  in
  let tracked = track_connection ~wire:(Request_wire.create ()) connection in
  let slices = 4 in
  let payload =
    String.init ((slices * request_slice_bytes) + 5) (fun i -> Char.chr (i mod 251))
  in
  let turns =
    turns_beside (fun () -> Eio.Flow.write tracked [ Cstruct.of_string payload ])
  in
  String.equal (Buffer.contents received) payload
  && List.for_all (fun length -> length <= request_slice_bytes) !writes
  && List.length !writes = slices + 1
  && turns >= slices
;;

(* The peer closed and something upstream reported it as prose.

   cohttp-eio reads the response through the flow above, and on a closed
   connection [Io.Response.read] answers [`Eof], which it turns into
   [Failure "connection closed by peer"] (cohttp-eio/client.ml:60).
   [classify_network_exn] declines to read that message — inventing a network
   kind from prose is how a classifier starts guessing — so the exception used
   to escape [with_post_stream] entirely. It then reached the runtime runner's
   outermost handler and was recorded as [internal_unhandled_exception], an
   internal defect. It is not one: the socket ended. masc counts that against
   the keeper's crash threshold, so a provider hanging up walked keepers toward
   termination (masc#29951; 185 occurrences over 2026-08-18/20/24).

   The evidence here is structural, not textual. [track_connection] routes
   every transport read through one [single_read], and nothing but a real
   [End_of_file] on the socket sets the flag, so a set flag at the moment an
   unclassified exception surfaces means the read that failed is the close. The
   original exception text is kept as the message. *)
let eof_error exn =
  NetworkError { message = Printexc.to_string exn; kind = End_of_file }
;;

(* A cohttp client whose requests all go over [conn]. [wire] records what
   this request's reads and writes on [conn] showed: whether a read met the
   transport's end of file, whether a write raised, how many response bytes
   came back. *)
let tracked_client ~wire conn =
  let tracked = track_connection ~wire conn in
  Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> tracked)
;;

(* A request's connection: opened for this request alone, or leased from a
   cache. [end_connection] ends either: a one-shot connection cannot be
   parked, and a leased one ends through its cache's [release]. *)
type held_connection =
  | One_shot of connection
  | Leased of Http_client_cache.lease

let held_flow = function
  | One_shot connection -> connection
  | Leased lease -> Http_client_cache.lease_connection lease
;;

let open_connection cache ~sw ~net ~origin =
  match cache with
  | None ->
    let* connection = make_connection ~sw ~net ~origin () in
    Ok (One_shot connection)
  | Some { pool; tls_config } ->
    let* lease =
      Http_client_cache.checkout pool (cache_key_of_origin origin) ~create:(fun ~sw ->
        make_connection ?tls_config ~sw ~net ~origin ())
    in
    Ok (Leased lease)
;;

(** Ends a request's connection. A leased one goes back through [verdict]
    (RFC-0492 §3.2); one opened for the request alone is closed. *)
let end_connection held verdict =
  match held with
  | One_shot connection -> Eio.Resource.close connection
  | Leased lease -> Http_client_cache.release lease verdict
;;

(** Run [f client] over a connection leased from [cache], or opened for this
    request alone when [cache] is omitted. The connection ends through
    {!end_connection} either way.

    [f] receives the caller switch and [transport_eof_seen], which is set
    once a read of the connection met the transport's end of file, and
    returns its result with the {!Reuse_verdict.t} for the exchange it read.
    [Error] and exceptions close the connection as [Request_not_delivered]
    when a write call raised an error the transport named as the peer's close
    and no response byte came back ({!Request_wire.delivery}), and as
    [Request_failed] otherwise. A connection whose transport reported end of
    file closes as [Transport_ended] even when [f] answered: a body with no
    declared length ends at the peer's close. An exception raised after that
    end of file is the peer's close, and is returned as {!eof_error}. *)
let with_client ?cache ~sw ~net ~origin f =
  let* conn = open_connection cache ~sw ~net ~origin in
  let wire = Request_wire.create () in
  let eof_seen = Request_wire.eof_seen wire in
  let client = tracked_client ~wire (held_flow conn) in
  let verdict = ref (Reuse_verdict.Close Request_failed) in
  Fun.protect
    ~finally:(fun () ->
      try end_connection conn !verdict with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Diag.warn "http_client" "with_client cleanup failed: %s" (Printexc.to_string exn))
    (fun () ->
       match f ~sw ~transport_eof_seen:eof_seen client with
       | Ok (result, reuse) ->
         verdict := if !eof_seen then Close Transport_ended else reuse;
         Ok result
       | Error error ->
         verdict := Close (failure_close_reason wire);
         Error error
       | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
       | exception exn ->
         verdict := Close (failure_close_reason wire);
         (match classify_network_exn exn with
          | Some error -> Error error
          | None when !eof_seen -> Error (eof_error exn)
          | None -> raise exn))
;;

module Safe_cohttp_response_flow = struct
  let min_chunk_read_len = 65_536

  type t =
    { source : [ `Flow | `R ] Eio.Resource.t
    ; reusable_buf : Cstruct.t
    ; mutable rem_off : int
    ; mutable rem_len : int
    }

  let create (source : [> Eio.Flow.source_ty ] Eio.Resource.t) =
    { source = (source :> [ `Flow | `R ] Eio.Resource.t)
    ; reusable_buf = Cstruct.create min_chunk_read_len
    ; rem_off = 0
    ; rem_len = 0
    }
  ;;

  let read_methods = []

  let single_read t dst =
    let dst_len = Cstruct.length dst in
    if dst_len = 0
    then 0
    else if t.rem_len > 0
    then (
      let to_copy = min t.rem_len dst_len in
      Cstruct.blit t.reusable_buf t.rem_off dst 0 to_copy;
      t.rem_off <- t.rem_off + to_copy;
      t.rem_len <- t.rem_len - to_copy;
      to_copy)
    else (
      t.rem_off <- 0;
      if dst_len >= min_chunk_read_len
      then (
        let count = Eio.Flow.single_read t.source dst in
        if count <= 0 then raise End_of_file else count)
      else (
        let count = Eio.Flow.single_read t.source t.reusable_buf in
        if count <= 0
        then raise End_of_file
        else (
          let to_copy = min count dst_len in
          Cstruct.blit t.reusable_buf 0 dst 0 to_copy;
          t.rem_off <- to_copy;
          t.rem_len <- count - to_copy;
          to_copy)))
  ;;
end

let safe_cohttp_response_flow (source : [> Eio.Flow.source_ty ] Eio.Resource.t)
  : [> Eio.Flow.source_ty ] Eio.Resource.t
  =
  let state = Safe_cohttp_response_flow.create source in
  let operations =
    Eio.Resource.handler
      (Eio.Resource.bindings (Eio.Flow.Pi.source (module Safe_cohttp_response_flow)))
  in
  Eio.Resource.T (state, operations)
;;

(* Whether [body], read to where cohttp ended it, reached the end its
   response's framing declares. cohttp ends a body at the peer's close as it
   does at the framing's end, so the end is checked here (RFC 9112 §8). A
   Content-Length body is complete at its declared length. A chunked body
   that ends at its zero-sized chunk is read without meeting the transport's
   end of file, so one that met it was cut. A response that declares neither
   ends where the server closes the connection (RFC 9112 §6.3 rule 8): the
   close is its end. *)
let body_reached_its_end ~response ~transport_eof_seen body =
  match Cohttp.Response.has_body response, Cohttp.Response.encoding response with
  | `No, (Http.Transfer.Fixed _ | Http.Transfer.Chunked | Http.Transfer.Unknown) -> true
  | (`Yes | `Unknown), Http.Transfer.Fixed declared ->
    Int64.equal (Int64.of_int (String.length body)) declared
  | (`Yes | `Unknown), Http.Transfer.Chunked -> not !transport_eof_seen
  | (`Yes | `Unknown), Http.Transfer.Unknown -> true
;;

(* The whole body of [response]. A body the peer's close cut short is the
   peer's close, not an answer: what arrived of it is not returned. *)
let read_response_body ~response ~transport_eof_seen resp_body =
  match
    let safe_body = safe_cohttp_response_flow resp_body in
    Eio.Buf_read.(of_flow ~max_size:Api_common.max_response_body safe_body |> take_all)
  with
  | body when body_reached_its_end ~response ~transport_eof_seen body -> Ok body
  | body ->
    Error
      (NetworkError
         { message =
             Printf.sprintf
               "the peer closed the connection %d bytes into a response body, before \
                the body's declared end"
               (String.length body)
         ; kind = End_of_file
         })
  | exception Eio.Buf_read.Buffer_limit_exceeded ->
    Error
      (ProviderFailure
         { kind = Response_body_too_large { limit_bytes = Api_common.max_response_body }
         ; message =
             Printf.sprintf
               "provider response exceeded %d bytes; connection closed without draining"
               Api_common.max_response_body
         })
;;

let get_sync ?cache ?clock ?timeout_s ~sw ~net ~url ~headers () =
  let* deadline =
    resolve_explicit_deadline
      ~operation:"get_sync"
      ~parameter:"timeout_s"
      ~clock
      ~timeout_s
  in
  catch_network (fun () ->
    let* origin = parse_uri url in
    with_explicit_deadline deadline (fun () ->
      with_client ?cache ~sw ~net ~origin (fun ~sw ~transport_eof_seen client ->
        let hdr = Http.Header.of_list (maybe_add_connection_close ?cache headers) in
        let resp, resp_body =
          Cohttp_eio.Client.get ~sw client ~headers:hdr origin.uri
        in
        let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
        let resp_headers = Cohttp.Response.headers resp in
        let* body_str =
          read_response_body ~response:resp ~transport_eof_seen resp_body
        in
        Ok
          ( { status = code
            ; body = body_str
            ; retry_after_header = retry_after_header_of_response_headers resp_headers
            ; content_type = content_type_of_response_headers resp_headers
            }
          , Reuse_verdict.decide ~request_headers:hdr ~response:resp ~body:`Drained ))))
;;

(* Same receipt shape as get_sync over the DELETE verb. The Files API deletes
   by file id (RFC-0430 Phase 3) and answers with a JSON body even on 2xx, so
   the caller keeps reading status + body the same way. *)
let delete_sync ?cache ?clock ?timeout_s ~sw ~net ~url ~headers () =
  let* deadline =
    resolve_explicit_deadline
      ~operation:"delete_sync"
      ~parameter:"timeout_s"
      ~clock
      ~timeout_s
  in
  catch_network (fun () ->
    let* origin = parse_uri url in
    with_explicit_deadline deadline (fun () ->
      with_client ?cache ~sw ~net ~origin (fun ~sw ~transport_eof_seen client ->
        let hdr = Http.Header.of_list (maybe_add_connection_close ?cache headers) in
        let resp, resp_body =
          Cohttp_eio.Client.delete ~sw client ~headers:hdr origin.uri
        in
        let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
        let resp_headers = Cohttp.Response.headers resp in
        let* body_str =
          read_response_body ~response:resp ~transport_eof_seen resp_body
        in
        Ok
          ( { status = code
            ; body = body_str
            ; retry_after_header = retry_after_header_of_response_headers resp_headers
            ; content_type = content_type_of_response_headers resp_headers
            }
          , Reuse_verdict.decide ~request_headers:hdr ~response:resp ~body:`Drained ))))
;;

let post_sync ?cache ?clock ?timeout_s ~sw ~net ~url ~headers ~body () =
  Http_request_observer.with_call ~mode:Synchronous ~body @@ fun observation ->
  let* deadline =
    resolve_explicit_deadline
      ~operation:"post_sync"
      ~parameter:"timeout_s"
      ~clock
      ~timeout_s
  in
  catch_network (fun () ->
    let* origin = parse_uri url in
    with_explicit_deadline deadline (fun () ->
      with_client ?cache ~sw ~net ~origin (fun ~sw ~transport_eof_seen client ->
        (* Explicitly set Content-Length to prevent chunked transfer encoding.
           Ollama's yyjson parser rejects chunked bodies with
           "Value looks like object, but can't find closing '}' symbol". *)
        let headers_with_length =
          ("content-length", string_of_int (String.length body))
          :: maybe_add_connection_close ?cache headers
        in
        let hdr = Http.Header.of_list headers_with_length in
        Http_request_observer.dispatch_entered observation;
        let resp, resp_body =
          Cohttp_eio.Client.post
            ~sw
            client
            ~headers:hdr
            ~body:(Cohttp_eio.Body.of_string body)
            origin.uri
        in
        let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
        Http_request_observer.response_headers_received observation ~status:code;
        let resp_headers = Cohttp.Response.headers resp in
        let* body_str =
          read_response_body ~response:resp ~transport_eof_seen resp_body
        in
        Http_client_diagnostics.profile_opaque_client_error
          ~url
          ~code
          ~resp_headers
          ~request_headers:headers_with_length
          ~request_body:body
          ~response_body:body_str;
        Ok
          ( { status = code
            ; body = body_str
            ; retry_after_header = retry_after_header_of_response_headers resp_headers
            ; content_type = content_type_of_response_headers resp_headers
            }
          , Reuse_verdict.decide ~request_headers:hdr ~response:resp ~body:`Drained ))))
;;

let post_sync_once_after_validation
      ?cache
      ~connect_deadline
      ~body_deadline
      ~net
      ~(request : validated_sync_request)
      ()
  =
  Http_request_observer.with_call ~mode:Synchronous ~body:request.body @@ fun observation ->
  Eio.Switch.run
  @@ fun sw ->
  let { origin; header; body } = request in
  let phase = ref Before_dispatch in
  let status = ref None in
  let connection = ref None in
  let wire = Request_wire.create () in
  let transport_eof_seen = Request_wire.eof_seen wire in
  let fail error =
    match !phase, !status with
    | Before_dispatch, None -> Error (Before_dispatch_error error)
    | Dispatch_started, None -> Error (Dispatch_started_error error)
    | Response_received, Some status -> Error (Response_received_error { status; error })
    | Before_dispatch, Some _ | Dispatch_started, Some _ | Response_received, None ->
      invalid_arg "Http_client.post_sync_once: inconsistent receipt state"
  in
  let end_request_connection verdict =
    match !connection with
    | None -> ()
    | Some conn ->
      connection := None;
      (try Eio.Cancel.protect (fun () -> end_connection conn verdict) with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         Diag.warn "http_client" "post_sync_once cleanup failed: %s" (Printexc.to_string exn))
  in
  let release_connection reason = end_request_connection (Close reason) in
  (* An unclassified exception is still a transport failure, and this function
     returns a result. Re-raising it made the return type a half-truth: cohttp-eio
     signals a peer close with [failwith "connection closed by peer"]
     (cohttp-eio/client.ml:60), classify_network_exn rightly answers [None] for prose
     rather than inventing a network kind, and the exception then escaped every
     caller. Two suites caught it — exact-output single-surface's receipt phase
     matrix and one-dispatch framing's stale-cache case — through different call
     paths, which is the signal that the fix belongs at this single choke point
     rather than at each boundary.

     Reserved exceptions (cancellation) are re-raised first, unchanged. When the
     tracked connection saw the transport's end of file, the exception is that
     close, as on the stream path ({!eof_error}): a parked connection the peer
     had closed fails the way a fresh one does (RFC-0492 §3.3).
     [Unknown_provider_failure] states that the failure was not classified instead
     of guessing a kind; the message is diagnostics only, per the note on
     [provider_failure_to_string] telling consumers to branch on the kind and never
     parse the string. *)
  let http_error_of_exn exn =
    match classify_network_exn exn with
    | Some error -> error
    | None ->
      end_request_connection (Close (failure_close_reason wire));
      Reserved_exn.reraise_if_reserved exn;
      if !transport_eof_seen
      then eof_error exn
      else
        ProviderFailure
          { kind = Unknown_provider_failure { reason = Some (Printexc.to_string exn) }
          ; message = "unclassified transport exception"
          }
  in
  let fail_exn exn = Error (http_error_of_exn exn) in
  let total_started_at =
    match body_deadline with
    | Unbounded -> None
    | Bounded (clock, _) -> Some (clock, Eio.Time.now clock)
  in
  let total_deadline_error timeout_s =
    TimeoutError
      { message =
          Printf.sprintf
            "post_sync_once body_timeout_s total deadline exceeded after %.17g seconds"
            timeout_s
      ; phase = Wall_clock
      }
  in
  let headers_deadline =
    match connect_deadline, body_deadline with
    | Unbounded, Unbounded -> None
    | Bounded (clock, timeout_s), Unbounded -> Some (clock, timeout_s, `Connect)
    | Unbounded, Bounded (clock, timeout_s) -> Some (clock, timeout_s, `Total)
    | Bounded (connect_clock, connect_timeout_s), Bounded (body_clock, body_timeout_s) ->
      if connect_timeout_s <= body_timeout_s
      then Some (connect_clock, connect_timeout_s, `Connect)
      else Some (body_clock, body_timeout_s, `Total)
  in
  let with_headers_deadline f =
    match headers_deadline with
    | None -> f ()
    | Some (clock, timeout_s, owner) ->
      (match Under_deadline.run clock timeout_s f with
       | Ok result -> result
       | Error `Timeout ->
         Error
           (match owner with
            | `Connect ->
              TimeoutError
                { message =
                    Printf.sprintf
                      "post_sync_once connect_timeout_s exceeded after %.17g seconds"
                      timeout_s
                ; phase = Http_operation
                }
            | `Total -> total_deadline_error timeout_s))
  in
  let post_result =
    try
      with_headers_deadline (fun () ->
        let* conn = open_connection cache ~sw ~net ~origin in
        connection := Some conn;
        let client = tracked_client ~wire (held_flow conn) in
        phase := Dispatch_started;
        Http_client_phase_observer.observe Http_client_phase_observer.Dispatch_started;
        Http_request_observer.dispatch_entered observation;
        let response, response_body =
          Cohttp_eio.Client.post
            ~sw
            client
            ~headers:header
            ~body:(Cohttp_eio.Body.of_string body)
            origin.uri
        in
        let response_status =
          Cohttp.Response.status response |> Cohttp.Code.code_of_status
        in
        Http_request_observer.response_headers_received observation ~status:response_status;
        let response_header_evidence, retry_after_header =
          Cohttp.Response.headers response |> capture_response_header_evidence
        in
        phase := Response_received;
        status := Some response_status;
        Http_client_phase_observer.observe
          (Http_client_phase_observer.Response_received response_status);
        Ok
          ( response
          , response_body
          , response_status
          , response_header_evidence
          , retry_after_header ))
    with
    | Eio.Time.Timeout as exn ->
      release_connection Request_failed;
      raise exn
    | exn -> fail_exn exn
  in
  match post_result with
  | Error error ->
    end_request_connection (Close (failure_close_reason wire));
    fail error
  | Ok
      ( response
      , response_body
      , response_status
      , response_header_evidence
      , retry_after_header ) ->
    let body_outcome =
      try
        match body_deadline, total_started_at with
        | Unbounded, None ->
          (match read_response_body ~response ~transport_eof_seen response_body with
           | Ok body -> `Body body
           | Error error -> `Failed error)
        | Bounded (clock, timeout_s), Some (_, started_at) ->
          let elapsed = Eio.Time.now clock -. started_at in
          let remaining = timeout_s -. elapsed in
          if remaining <= 0.0
          then `Deadline_passed timeout_s
          else (
            match
              Under_deadline.run clock remaining (fun () ->
                read_response_body ~response ~transport_eof_seen response_body)
            with
            | Ok (Ok body) -> `Body body
            | Ok (Error error) -> `Failed error
            | Error `Timeout -> `Deadline_passed timeout_s)
        | Unbounded, Some _ | Bounded _, None ->
          invalid_arg "Http_client.post_sync_once: inconsistent total deadline state"
      with
      | Eio.Time.Timeout as exn ->
        release_connection Request_failed;
        raise exn
      | exn -> `Failed (http_error_of_exn exn)
    in
    let response_of body_receipt =
      let body = refusal_body_text body_receipt in
      { response =
          { status = response_status
          ; body
          ; retry_after_header
          ; content_type = content_type_of_response_headers (Cohttp.Response.headers response)
          }
      ; body_receipt
      ; response_header_evidence
      }
    in
    (match body_outcome with
     | `Failed error ->
       release_connection Request_failed;
       fail error
     | `Deadline_passed timeout_s when is_success_status response_status ->
       (* The body is the answer; without it there is none. *)
       release_connection Request_failed;
       fail (total_deadline_error timeout_s)
     | `Deadline_passed _ ->
       (* A refusing status line is the provider's answer, and it is already
          in hand with its headers: a body that does not arrive in time does
          not turn the refusal into silence. The connection has unread
          bytes on it and is not parked. *)
       release_connection Body_not_drained;
       Ok (response_of Not_received_in_window)
     | `Body response_body ->
       (* cohttp ends a body at the peer's close without an error, so the
          transport's end of file is read from the tracked connection. *)
       let body = if !transport_eof_seen then `Transport_ended else `Drained in
       end_request_connection
         (Reuse_verdict.decide ~request_headers:header ~response ~body);
       Ok (response_of (Received response_body)))
;;

let dispatch_sync_request
      ?cache
      ?clock
      ?connect_timeout_s
      ?body_timeout_s
      ~net
      request
      ()
  =
  let before_dispatch error = Error (Before_dispatch_error error) in
  match
    resolve_explicit_deadline
      ~operation:"post_sync_once"
      ~parameter:"connect_timeout_s"
      ~clock
      ~timeout_s:connect_timeout_s
  with
  | Error error -> before_dispatch error
  | Ok connect_deadline ->
    (match
       resolve_explicit_deadline
         ~operation:"post_sync_once"
         ~parameter:"body_timeout_s"
         ~clock
         ~timeout_s:body_timeout_s
     with
     | Error error -> before_dispatch error
     | Ok body_deadline ->
       post_sync_once_after_validation
         ?cache
         ~connect_deadline
         ~body_deadline
         ~net
         ~request
         ())
;;

let post_sync_once_with_evidence
      ?cache
      ?clock
      ?connect_timeout_s
      ?body_timeout_s
      ~net
      ~url
      ~headers
      ~body
      ()
  =
  match prepare_sync_request ~url ~headers ~body with
  | Error error -> Error (Before_dispatch_error error)
  | Ok request ->
    dispatch_sync_request
      ?cache
      ?clock
      ?connect_timeout_s
      ?body_timeout_s
      ~net
      request
      ()
;;

let post_sync_once
      ?cache
      ?clock
      ?connect_timeout_s
      ?body_timeout_s
      ~net
      ~url
      ~headers
      ~body
      ()
  =
  match
    post_sync_once_with_evidence
      ?cache
      ?clock
      ?connect_timeout_s
      ?body_timeout_s
      ~net
      ~url
      ~headers
      ~body
      ()
  with
  | Ok receipt -> Ok receipt.response
  | Error error -> Error error
;;


(* Which budget bounds the phase before the response headers, so the
   timeout it raises is reported as the budget that was spent. *)
type pre_header_budget =
  | Connect_budget
  | First_event_budget

(* The phase before the response headers -- the connection (TCP, TLS), the
   request and the wait for the status line -- runs under the narrower of
   the connect budget and the first-event budget. The first-event budget is
   the operator's word on how long a provider may stay silent before its
   first token, and silence before the headers is that silence: what this
   phase spends of it is handed to the reader, which arms the rest, so the
   budget is one window from the request to the first token. A server that
   accepts the request and never answers never reaches the reader. Two
   steps the window cannot end: [getaddrinfo] runs in a systhread with no
   cancellation, so a closed window is observed once the lookup returns,
   and the resolver's own timeout is the bound until then; and an https
   connection loads the system trust store ([Api_common.tls_client_config])
   synchronously on this domain, so no timer runs until it is back. The
   load is cached once it succeeds; a load that fails is made again,
   synchronously, by every https connection until one succeeds. On a
   connection that loads the store the two steps are one stretch, the
   load and then the lookup with no suspension between them, so the
   window is observed after their sum, not after the longer. *)
let pre_header_deadline
      ~(connect : 'clock explicit_deadline)
      ~(first_event : 'clock explicit_deadline)
  : 'clock explicit_deadline * pre_header_budget
  =
  match connect, first_event with
  | Unbounded, Unbounded -> Unbounded, Connect_budget
  | (Bounded _ as connect), Unbounded -> connect, Connect_budget
  | Unbounded, (Bounded _ as first_event) -> first_event, First_event_budget
  | Bounded (clock, connect_s), Bounded (_, first_event_s) ->
    if connect_s <= first_event_s
    then Bounded (clock, connect_s), Connect_budget
    else Bounded (clock, first_event_s), First_event_budget
;;

let%test "pre-header phase: a first-event budget stands in for an undeclared connect budget" =
  match pre_header_deadline ~connect:Unbounded ~first_event:(Bounded ((), 600.0)) with
  | Bounded ((), 600.0), First_event_budget -> true
  | (Unbounded | Bounded (_, _)), (Connect_budget | First_event_budget) -> false
;;

let%test "pre-header phase: the narrower declared budget names itself" =
  match
    ( pre_header_deadline ~connect:(Bounded ((), 30.0)) ~first_event:(Bounded ((), 600.0))
    , pre_header_deadline ~connect:(Bounded ((), 900.0)) ~first_event:(Bounded ((), 600.0)) )
  with
  | (Bounded ((), 30.0), Connect_budget), (Bounded ((), 600.0), First_event_budget) -> true
  | ( ((Unbounded | Bounded (_, _)), (Connect_budget | First_event_budget))
    , ((Unbounded | Bounded (_, _)), (Connect_budget | First_event_budget)) ) -> false
;;

let%test "pre-header phase: nothing declared stays unbounded" =
  match pre_header_deadline ~connect:Unbounded ~first_event:Unbounded with
  | Unbounded, Connect_budget -> true
  | (Unbounded, First_event_budget) | (Bounded (_, _), _) -> false
;;

let with_post_stream
      ?cache
      ?clock
      ?connect_timeout_s
      ?first_event_timeout_s
      ?on_response_status
      ~net
      ~url
      ~headers
      ~body
      ~f
      ()
  =
  Http_request_observer.with_call ~mode:Streaming ~body @@ fun observation ->
  let* connect_deadline =
    resolve_explicit_deadline
      ~operation:"with_post_stream"
      ~parameter:"connect_timeout_s"
      ~clock
      ~timeout_s:connect_timeout_s
  in
  let* first_event_deadline =
    resolve_explicit_deadline
      ~operation:"with_post_stream"
      ~parameter:"first_event_timeout_s"
      ~clock
      ~timeout_s:first_event_timeout_s
  in
  let deadline, pre_header_budget =
    pre_header_deadline ~connect:connect_deadline ~first_event:first_event_deadline
  in
  (* When the request's window opens, on the clock the budgets are counted
     on. What the pre-header phase spends of the first-event budget is
     handed to [f], so the reader arms the rest of that budget and not a
     second full one: the budget is one window from here to the first
     token. Without a clock no budget is armed anywhere and the elapsed time
     is not read. *)
  let window_opened = Option.map (fun clock -> clock, Eio.Time.now clock) clock in
  Eio.Switch.run
  @@ fun sw ->
  (* Phase 1a: the connection, the request and the response headers, one
     window under [deadline] (see [pre_header_deadline]); a refusal's body
     is then read under what that window has left, and a body that does not
     arrive in time still yields the refusal, with the status and headers
     received and no body. The connection is made inside the window:
     the TCP connect and the TLS handshake are the first things a dead or
     blackholed endpoint stalls on. Cohttp_eio.Client.post returns once
     headers are parsed (body is a lazy flow), so a 200's body is left to
     [f]: wrapping only this stage in [catch_network] keeps a pre-header
     stall as a [TimeoutError] named for its budget without absorbing
     body-phase timeouts (first-token / prefill wait, inter-chunk idle).

     Streaming is handled manually rather than through [with_client] so the
     connection is NOT parked until [f] has fully consumed the reader. *)
  let post_result =
    catch_network (fun () ->
      let* origin = parse_uri url in
      let headers_with_length =
        ("content-length", string_of_int (String.length body))
        :: maybe_add_connection_close ?cache headers
      in
      let hdr = Http.Header.of_list headers_with_length in
      (* The window as an instant, so the refusal body below can run under
         what the headers left of it. *)
      let closes_at =
        match deadline with
        | Unbounded -> None
        | Bounded (clock, timeout_s) -> Some (clock, Eio.Time.now clock +. timeout_s)
      in
      (* A connection handed back as the window closes is the connection:
         the window's verdict stands only when nothing had returned. The
         timeout is raised as [Eio.Time.Timeout] so [catch_network] names it
         as it names any window's. *)
      let under_the_window f =
        match closes_at with
        | None -> f ()
        | Some (clock, closes_at) ->
          (match Under_deadline.run clock (closes_at -. Eio.Time.now clock) f with
           | Ok answer -> answer
           | Error `Timeout -> raise Eio.Time.Timeout)
      in
      (* Held outside the window for the cancellation that comes from
         outside it, at the handoff. *)
      let connection = ref None in
      let wire = Request_wire.create () in
      let close_connection () =
        match !connection with
        | None -> ()
        | Some conn ->
          connection := None;
          end_connection conn (Close (failure_close_reason wire))
      in
      let* answer =
        match
          under_the_window (fun () ->
            let* conn = open_connection cache ~sw ~net ~origin in
            connection := Some conn;
            let transport_eof_seen = Request_wire.eof_seen wire in
            let client = tracked_client ~wire (held_flow conn) in
            Http_request_observer.dispatch_entered observation;
            match
              Cohttp_eio.Client.post
                ~sw
                client
                ~headers:hdr
                ~body:(Cohttp_eio.Body.of_string body)
                origin.uri
            with
            | resp, resp_body ->
              let status = Cohttp.Response.status resp in
              Http_request_observer.response_headers_received observation
                ~status:(Cohttp.Code.code_of_status status);
              Option.iter
                (fun observe -> observe (Cohttp.Code.code_of_status status))
                on_response_status;
              (match status with
               | `OK -> Ok (`Stream_headers (conn, transport_eof_seen, resp, resp_body))
               | _ -> Ok (`Refusal_headers (conn, transport_eof_seen, resp, resp_body)))
            | exception (Eio.Cancel.Cancelled _ as exn) ->
              (* The window closing arrives here as cancellation, and so does
                 an outer cancel; either way the socket must not outlive the
                 request on the cache's switch, and the cancellation itself
                 is not something to classify. *)
              Eio.Cancel.protect close_connection;
              raise exn
            | exception exn ->
              (* A peer that closes during the request or the status line
                 reads as End_of_file through the tracked connection; an
                 exception the classifier does not know is that EOF when the
                 tracker saw one, and escapes otherwise. *)
              close_connection ();
              (match classify_network_exn exn with
               | Some e -> Error e
               | None when !transport_eof_seen -> Error (eof_error exn)
               | None -> raise exn))
        with
        | answer -> answer
        | exception (Eio.Cancel.Cancelled _ as exn) ->
          Eio.Cancel.protect close_connection;
          raise exn
        | exception exn ->
          (* [Eio.Time.Timeout] from the window, or the status observer. *)
          close_connection ();
          raise exn
      in
      match answer with
      | `Refusal_headers (conn, transport_eof_seen, resp, resp_body) ->
        let code = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
        let resp_headers = Cohttp.Response.headers resp in
        let retry_after_header = retry_after_header_of_response_headers resp_headers in
        (* A refusal's body is the rest of the provider's answer, read under
           what the window has left. The status line and its headers are
           already the answer: a body that does not arrive in time does not
           turn a refusal into silence, so the refusal is returned with the
           status and headers received and its body [Not_received_in_window]
           -- which a consumer must not read as a body the provider left
           empty, the reason it carried being unread. A refusal's connection
           ends through the same verdict as an answer's (RFC-0492 §3.2): a
           refusal read to its end on a persistent connection is parked. *)
        let refusal body = Error (HttpError { code; body; retry_after_header }) in
        let body_state = ref `Failed in
        Fun.protect
          ~finally:(fun () ->
            let body =
              match !body_state with
              | `Drained when !transport_eof_seen -> `Transport_ended
              | (`Drained | `Not_drained | `Failed) as state -> state
            in
            end_connection conn
              (Reuse_verdict.decide ~request_headers:hdr ~response:resp ~body))
          (fun () ->
             let read_body () =
               match
                 read_response_body ~response:resp ~transport_eof_seen resp_body
               with
               | Ok refusal_body -> Ok refusal_body
               | Error err -> Error err
               | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
               | exception exn ->
                 (match classify_network_exn exn with
                  | Some e -> Error e
                  | None when !transport_eof_seen -> Error (eof_error exn)
                  | None -> raise exn)
             in
             (* No guard on a window already spent: [Under_deadline.run]
                keeps the read's outcome whenever the read finished, and a
                body cohttp already buffered with the headers finishes
                without suspending. A read that does suspend ends at the
                window as it did. *)
             let body_result =
               match closes_at with
               | None -> Ok (read_body ())
               | Some (clock, closes_at) ->
                 Under_deadline.run clock (closes_at -. Eio.Time.now clock) read_body
             in
             match body_result with
             | Ok (Ok refusal_body) ->
               body_state := `Drained;
               Http_client_diagnostics.profile_opaque_client_error
                 ~url
                 ~code
                 ~resp_headers
                 ~request_headers:headers_with_length
                 ~request_body:body
                 ~response_body:refusal_body;
               refusal (Received refusal_body)
             | Ok (Error err) -> Error err
             | Error `Timeout ->
               body_state := `Not_drained;
               refusal Not_received_in_window)
      | `Stream_headers (conn, transport_eof_seen, resp, resp_body) ->
        (try
           (* EOF proves the body was drained; it does not prove the connection
              may be reused. A response with neither content-length nor chunked
              framing is delimited BY the close, so its EOF arrives precisely
              because the peer went away. The same predicate the synchronous
              path uses answers the second question. *)
           let reuse = Reuse_verdict.decide ~request_headers:hdr ~response:resp in
           let safe_body = safe_cohttp_response_flow resp_body in
           let reader =
             Eio.Buf_read.of_flow ~max_size:Api_common.max_response_body safe_body
           in
           Ok (conn, reuse, transport_eof_seen, reader)
         with
         | exn ->
           end_connection conn (Close Request_failed);
           (match classify_network_exn exn with
            | Some e -> Error e
            | None when !transport_eof_seen -> Error (eof_error exn)
            | None -> raise exn)))
  in
  (* [catch_network] names every [Eio.Time.Timeout] [Http_operation]. When
     the window that closed was the first-event budget, the provider was
     silent for the whole time the operator allowed before a first token,
     and the phase says so: the consumers that rotate on a silent prefill
     read [First_token], and a connect budget that was never declared is
     not what ran out. *)
  let post_result =
    match post_result, pre_header_budget with
    | Error (TimeoutError { phase = Http_operation; _ }), First_event_budget ->
      Error
        (TimeoutError
           { message = "no response headers before the first-event budget ran out"
           ; phase = First_token
           })
    | ((Ok _ | Error (HttpError _)), (Connect_budget | First_event_budget))
    | (Error (NetworkError _), (Connect_budget | First_event_budget))
    | ( Error
          (TimeoutError
             { message = _
             ; phase =
                 ( Queue
                 | First_token
                 | Wall_clock
                 | Capacity_backpressure
                 | Http_operation
                 | Non_streaming_body
                 | Stream_body
                 | Stream_idle _
                 | Provider_step
                 | Cli_stdout_idle
                 | Unknown_timeout )
             })
      , (Connect_budget | First_event_budget) )
    | (Error (AcceptRejected _), (Connect_budget | First_event_budget))
    | (Error (ProviderTerminal _), (Connect_budget | First_event_budget))
    | (Error (ProviderFailure _), (Connect_budget | First_event_budget)) -> post_result
  in
  (* Phase 1b: body consumption. Deliberately OUTSIDE [catch_network]: a
     body-phase [Eio.Time.Timeout] is phase-distinct from the connect /
     headers phase and must not be mislabelled [Http_operation]. [f] owns
     phase-aware timeout handling and must convert [Eio.Time.Timeout] into a
     typed [Error] (see [Complete_stream.body_logic] and the Streaming
     callers). A body-phase timeout that [f] lets propagate escapes this
     function as the raw exception.

     The connection is parked back into the cache only after [f] returns
     successfully, ensuring the reader is no longer using the flow. *)
  let* conn, reuse, transport_eof_seen, reader = post_result in
  let pre_header_elapsed_s =
    match window_opened with
    | Some (clock, opened_at) -> Eio.Time.now clock -. opened_at
    | None -> 0.0
  in
  let body_result =
    try Ok (f ~pre_header_elapsed_s reader) with
    | Eio.Time.Timeout ->
      (* Body-phase timeout. Stream-state-aware callers ([Complete_stream])
           catch this inside [f] and emit the precise [First_token] /
           [Stream_idle] phase. Callers that let it propagate (e.g.
           [Streaming]) get [Unknown_timeout] as a safe default rather
           than it being mislabelled [Http_operation] (the connect /
           headers phase, which a body-phase timeout is not). *)
      Error
        (TimeoutError
           { message = "stream body timed out (awaiting first token / inter-chunk idle)"
           ; phase = Unknown_timeout
           })
    | Eio.Cancel.Cancelled _ as exn ->
      (* Checked before the end-of-file branch below: a cancellation after the
         transport reported end of file is still a cancellation. The
         connection is closed first, so a cached socket does not stay open
         on the cache's switch. *)
      Eio.Cancel.protect (fun () -> end_connection conn (Close Request_failed));
      raise exn
    | exn ->
      (match classify_network_exn exn with
       | Some e -> Error e
       | None when !transport_eof_seen -> Error (eof_error exn)
       | None ->
         (* Other unclassified exceptions escape, so close the connection
            before re-raising to avoid leaking a cached socket bound to the
            long-lived cache switch. *)
         Eio.Cancel.protect (fun () ->
           end_connection conn (Close Request_failed));
         raise exn)
  in
  let body =
    match body_result with
    | Error _ -> `Failed
    | Ok _ when !transport_eof_seen -> `Transport_ended
    | Ok _ when not (Eio.Buf_read.eof_seen reader) -> `Not_drained
    | Ok _ -> `Drained
  in
  end_connection conn (reuse ~body);
  body_result
;;

(* One W3C EventSource line, parsed per spec (§9.2.6 event stream
   interpretation):
   - empty line: event dispatch boundary
   - line starting with ':': comment (keepalive)
   - otherwise "name[:[ ]value]": a field; exactly one leading space is
     stripped from the value, and a line with no ':' is a field with an
     empty value.
   The previous implementation matched the literal prefixes "event: " /
   "data: " with index arithmetic, silently dropping spec-valid lines
   like "data:foo" (no space after the colon) — a provider or proxy
   that omits the optional space would make the whole stream vanish
   without a trace. *)
(* The field NAME is wire syntax; it is parsed into this closed type at the
   protocol boundary so no later stage compares strings again. Only [event] and
   [data] drive the state machine: EventSource also defines [id] and [retry],
   which this client does not implement (no reconnection), and the spec
   requires unknown names to be ignored — all three are the same thing to every
   reader below, so they share one constructor. *)
type sse_line =
  | Sse_blank
  | Sse_comment
  | Sse_event_type of string
  | Sse_data of string
  | Sse_ignored_field

(* What one dispatched event or line carried, as only the consumer's parser
   can tell. The reader keeps the first-event budget armed until the consumer
   reports the first [Output] and arms the inter-token idle budget after it.
   A provider's opening frame is not output: Responses sends
   [response.created] and Anthropic sends [message_start] before prefill and
   before any reasoning, so a reader that switched budgets on the first data
   line put a silent prefill under the short inter-token bound (gpt-5.6-luna,
   2026-09-10: "stream_idle_timeout_s deadline exceeded while
   awaiting_first_delta" 164 s into a turn). *)
type dispatched_event =
  | Prelude
  | Output

(* What the consumer wants after one dispatched event or line. A consumer that
   has stopped consuming must also stop the read, or the socket keeps
   delivering a body nobody reads until the provider finishes or a deadline
   fires — the caller pays for tokens it discards and the connection is held
   for the whole of it. Returned rather than asked for through a predicate so
   no caller can omit the decision; the same value carries what the event was,
   so no caller can omit that either. *)
type stream_continuation =
  | Continue of dispatched_event
  | Stop

(* WHATWG HTML 9.2.6 joins multiple [data] fields of one event with a single
   LF. Defined once so the size check below charges exactly what the join
   appends. *)
let sse_data_join_separator = "\n"

let classify_sse_field ~name ~value =
  match name with
  | "event" -> Sse_event_type value
  | "data" -> Sse_data value
  | _ -> Sse_ignored_field
;;

let parse_sse_line line =
  if String.length line = 0
  then Sse_blank
  else (
    match String.index_opt line ':' with
    | Some 0 -> Sse_comment
    | None -> classify_sse_field ~name:line ~value:""
    | Some i ->
      let value_start =
        if String.length line > i + 1 && line.[i + 1] = ' ' then i + 2 else i + 1
      in
      classify_sse_field
        ~name:(String.sub line 0 i)
        ~value:(String.sub line value_start (String.length line - value_start)))
;;

(* [Eio.Buf_read.line] accepts LF and CRLF, while EventSource also accepts a
   lone CR. Keep the bounded, cancellable buffered reader and consume all
   three legal line endings at this protocol boundary. An unterminated final
   line is returned once so [read_sse] can discard it as incomplete at EOF. *)
let read_sse_line reader =
  let line = Eio.Buf_read.take_while (fun ch -> ch <> '\n' && ch <> '\r') reader in
  match Eio.Buf_read.peek_char reader with
  | None -> if String.equal line "" then raise End_of_file else line
  | Some terminator ->
    (* [take_while] stopped, so [terminator] is LF or CR. *)
    Eio.Buf_read.char terminator reader;
    (if Char.equal terminator '\r'
     then
       match Eio.Buf_read.peek_char reader with
       | Some '\n' -> Eio.Buf_read.char '\n' reader
       | Some _ | None -> ());
    line
;;

let strip_initial_utf8_bom line =
  if
    String.length line >= 3 && line.[0] = '\xEF' && line.[1] = '\xBB' && line.[2] = '\xBF'
  then String.sub line 3 (String.length line - 3)
  else line
;;

let idle_timeout_without_clock site =
  invalid_arg
    (site
     ^ ": idle_timeout is set but no clock was supplied — the idle deadline would be \
        silently disarmed (pass ?clock, or drop ?idle_timeout)")
;;

let first_event_timeout_without_clock site =
  invalid_arg
    (site
     ^ ": a first-event bound (first_event_timeout or its body_timeout fallback) is set \
        but no clock was supplied — the first-event deadline would be silently disarmed \
        (pass ?clock, or drop the timeout)")
;;

let require_clock_when_idle ~site ~clock ~idle_timeout =
  match clock, idle_timeout with
  | None, Some _ ->
    (* Fail-loud contract: a configured idle deadline with no clock used
       to silently disarm and leave a stalled stream blocking forever
       (the read_sse idle-disarm bug family). Misconfiguration must fail
       at the call site, not at 3 a.m. as a hung fiber. *)
    idle_timeout_without_clock site
  | Some _, _ | None, None -> ()
;;

(* Agent Core contract: same fail-loud contract for the first-event (TTFT/prefill)
   deadline. Either an explicit [first_event_timeout] OR the [body_timeout]
   fallback that now backs it (see [armed_budget]) would
   silently disarm without a clock, leaving the prefill wait unbounded. The
   all-[None] case configures no first-event deadline at all, so there is
   nothing to disarm and nothing to reject. *)
let require_clock_when_first_event ~site ~clock ~first_event_timeout ~body_timeout =
  match clock with
  | Some _ -> ()
  | None ->
    (match first_event_timeout, body_timeout with
     | Some _, _ | None, Some _ -> first_event_timeout_without_clock site
     | None, None -> ())
;;

(* Agent Core contract: the caller-supplied knob a streaming deadline came from.
   Carried so a fired timeout can name the budget the operator must tune,
   rather than always blaming the inter-token idle knob. *)
type timeout_knob =
  | First_event_timeout
  | Body_timeout
  | Stream_idle_timeout

let timeout_knob_to_param = function
  | First_event_timeout -> "first_event_timeout_s"
  | Body_timeout -> "body_timeout_s"
  | Stream_idle_timeout -> "stream_idle_timeout_s"
;;

(* Resolution outcome for the first-event wait: either a bound with the knob it
   came from, or no bound at all. Keeping the knob attached to the value is what
   lets attribution reuse the resolver instead of re-deriving the precedence. *)
type first_event_bound =
  | Bounded of
      { knob : timeout_knob
      ; seconds : float
      }
  | Unarmed

(* Agent Core contract §4.2: resolve the effective first-event (TTFT/prefill) bound.
   Every arm returns a caller-supplied value — this function never invents a
   deadline of its own:

   - explicit [first_event_timeout] wins;
   - else [body_timeout], the total body budget callers already wire, but which
     did not reach the streaming reader before this fix (the production shape
     the RFC exists to repair: a long prefill bounded by the long budget
     instead of the short inter-token one);
   - else [idle_timeout], preserving the pre-RFC bound for callers that wired
     only an idle deadline — before this change that value also bounded the
     first event, and silently widening it would be an unrequested behaviour
     change;
   - else [None]: the caller configured no deadline on any channel, so the
     first-event wait stays unarmed exactly as it was. Inventing a default
     here would re-introduce the provider idle defaults that were deliberately
     removed (see [removed_provider_idle_defaults_upper_bound_s] in the
     streaming tests) and would be a hardcoded magic number besides.

   A dead connect on the all-[None] path is bounded by the connect timeout and
   by the caller's own total-call deadline, not by a budget this layer makes
   up. *)
let resolve_first_event_bound ~first_event_timeout ~body_timeout ~idle_timeout =
  match first_event_timeout, body_timeout, idle_timeout with
  | Some seconds, _, _ -> Bounded { knob = First_event_timeout; seconds }
  | None, Some seconds, _ -> Bounded { knob = Body_timeout; seconds }
  | None, None, Some seconds -> Bounded { knob = Stream_idle_timeout; seconds }
  | None, None, None -> Unarmed
;;

(* Which budget the reader had armed when a deadline fired. The reader moves
   from the first one to the second when the consumer reports its first
   [Output]; the consumer that names the knob passes the phase it derived from
   the same report, so the message cannot drift from the behaviour. *)
type budget_phase =
  | Before_first_output
  | After_first_output

(* Agent Core contract: name the knob whose value produced the deadline that fired, so
   an operator tunes the budget that actually governs. Derived from the SAME
   resolver as the armed bound — the precedence chain exists in exactly one
   place. Only the wait for the first output can be governed by something
   other than the idle knob; after it every read is inter-token idle by
   construction. *)
let governing_timeout_knob ~phase ~first_event_timeout ~body_timeout ~idle_timeout =
  match phase with
  | Before_first_output ->
    (match resolve_first_event_bound ~first_event_timeout ~body_timeout ~idle_timeout with
     | Bounded { knob; _ } -> knob
     | Unarmed -> Stream_idle_timeout)
  | After_first_output -> Stream_idle_timeout
;;

(* What one read is bounded by. The inter-line idle budget is a gap: every
   payload line starts it again. The first-event and body budgets are totals:
   they run from the first body read and no line extends them, so an opening
   frame or a keepalive payload cannot hold open a stream that never
   produces. When [idle_timeout] is the only value supplied it also bounds
   the first event, and it keeps its gap meaning there: that is the pre-RFC
   bound those callers had. *)
type armed_budget =
  | Gap of float
  | Total of float

let armed_budget ~phase ~first_event_timeout ~body_timeout ~idle_timeout =
  match phase with
  | After_first_output -> Option.map (fun seconds -> Gap seconds) idle_timeout
  | Before_first_output ->
    (match resolve_first_event_bound ~first_event_timeout ~body_timeout ~idle_timeout with
     | Bounded { knob = First_event_timeout | Body_timeout; seconds } -> Some (Total seconds)
     | Bounded { knob = Stream_idle_timeout; seconds } -> Some (Gap seconds)
     | Unarmed -> None)
;;

(* Run [read] inside what is left of the budget measured from [anchor],
   taking the anchor now when none is set, and raise [Eio.Time.Timeout] when
   the budget ends it.

   A read that started inside the budget and finished stands, even when it
   finished in the pass the budget ran out: what it read had been asked for
   in time. A read that starts once the budget has run out stands only when
   it never waited for the flow -- the bytes were already in a buffer between
   the socket and here, such as the delimiter that came with a first token,
   or a whole first event the response's opening chunk carried. A read that
   waited does not stand: a submitted read can still complete after its fiber
   was cancelled (io_uring hands over the bytes the kernel had already been
   asked for), so a stream that kept sending would otherwise outlast a total
   budget line by line.

   Whether it waited is what the cancellation says. The budget's arm cancels
   this read when it wins, and a read that took bytes already in hand never
   reaches a scheduling point to be cancelled at. Counting bytes named the
   wrong thing: this reader's buffer is the last of four between the socket
   and the parser, and a first token still sitting in the cohttp connection's
   buffer arrives here as new bytes. *)
let read_within_budget ~clock ~anchor ~seconds read =
  let anchored_at =
    match !anchor with
    | Some t -> t
    | None ->
      let t = Eio.Time.now clock in
      anchor := Some t;
      t
  in
  let remaining = anchored_at +. seconds -. Eio.Time.now clock in
  match
    Under_deadline.run clock remaining (fun () ->
      let line = read () in
      line, Eio.Fiber.is_cancelled ())
  with
  | Error `Timeout -> raise Eio.Time.Timeout
  | Ok (line, waited_for_the_flow) ->
    if Float.compare remaining 0. > 0 || not waited_for_the_flow
    then line
    else raise Eio.Time.Timeout
;;

(* A payload line was read under [budget]: a gap starts again, a total does
   not move. *)
let renew_after_payload ~anchor = function
  | Some (Gap _) -> anchor := None
  | Some (Total _) | None -> ()
;;

(* The consumer reported its first [Output]. Leaving a total budget, the gap
   budget measures from this moment, not from the first body read the total
   ran from; a gap budget before the first output is the same gap after it
   and keeps its anchor. *)
let enter_after_first_output ~phase ~anchor ~first_event_timeout ~body_timeout ~idle_timeout =
  match !phase with
  | After_first_output -> ()
  | Before_first_output ->
    phase := After_first_output;
    (match
       armed_budget
         ~phase:Before_first_output
         ~first_event_timeout
         ~body_timeout
         ~idle_timeout
     with
     | Some (Total _) -> anchor := None
     | Some (Gap _) | None -> ())
;;

exception
  Sse_event_too_large of
    { actual_bytes : int
    ; limit_bytes : int
    }

let read_sse
      ?clock
      ?idle_timeout
      ?first_event_timeout
      ?body_timeout
      ?(max_event_bytes = Api_common.max_response_body)
      ?(max_bodiless_body_bytes = 64 * 1024)
      ~reader
      ~on_data
      ?on_bodiless_body
      ()
  =
  let site = "read_sse" in
  if max_event_bytes <= 0 then invalid_arg "read_sse: max_event_bytes must be positive";
  if max_bodiless_body_bytes <= 0
  then invalid_arg "read_sse: max_bodiless_body_bytes must be positive";
  require_clock_when_idle ~site ~clock ~idle_timeout;
  require_clock_when_first_event ~site ~clock ~first_event_timeout ~body_timeout;
  (* SSE keepalive comments carry no payload. Skipping them inside the
     SAME budgeted read preserves the armed deadline so a
     provider that emits only keepalives still trips it when no real event
     arrives.
     Agent Core contract: the wait for the consumer's first [Output] is the
     time-to-first-token (prefill) window; bound it with
     [first_event_timeout] (a separate, larger liveness budget) rather than
     the short [idle_timeout], which arms only after that first output for
     inter-token idle. Which event is output is the consumer's call, returned
     from [on_data]: a provider's opening frame ([response.created],
     [message_start]) arrives before prefill and keeps this window armed. A
     silent prefill on a large context is slow-but-alive, not a hang, so it
     must not be cut by the inter-token idle value. When
     [first_event_timeout] is [None] the first-event wait falls back to
     [body_timeout] (the total body budget already wired by the caller), then to [idle_timeout] — the
     pre-RFC bound, kept so callers that wired only an idle deadline keep
     exactly their previous behaviour (see [armed_budget]).
     With nothing wired the wait stays unarmed, as before. Inter-token idle
     still guards once the stream produces. *)
  let phase = ref Before_first_output in
  (* The armed budget is anchored, never per read (see [armed_budget]). A
     total budget (first-event or body) is anchored at the first body read
     and nothing moves it, so an opening frame, a keepalive payload or any
     other event the consumer reports as [Prelude] does not buy the provider
     another full budget. A gap budget is anchored at the last PAYLOAD-bearing
     line: comments are consumed inside one window, [id]/[retry]/unknown
     fields and bare dispatch delimiters carry no payload either, and a
     per-read window would let a provider hold the stream open forever by
     emitting one ignorable line just under each budget. A blank delimiter
     cannot simply be swallowed inside the window (it must still reach [loop]
     to dispatch and to reset the event type), so the anchor, not the filter,
     is what closes that shape. *)
  let budget_anchor = ref None in
  let first_line = ref true in
  (* A 200 response the caller accepted as SSE sometimes carries no [data:]
     payload at all: some providers and gateways answer with a bare JSON
     error object instead of an event stream. Retain those raw lines -- only
     while no data payload has been dispatched, and only under
     [max_bodiless_body_bytes] -- so [on_bodiless_body] can read the envelope
     at EOF instead of the stream failing as merely incomplete. A body over
     the cap, or any dispatched data, drops the retention: the callback never
     sees a truncated body. *)
  let data_dispatched = ref false in
  let bodiless_body = Buffer.create 256 in
  let bodiless_body_over_cap = ref false in
  let read_protocol_line () =
    let line = read_sse_line reader in
    let line =
      if !first_line
      then (
        first_line := false;
        strip_initial_utf8_bom line)
      else line
    in
    (match on_bodiless_body with
     | None -> ()
     | Some _ ->
       if (not !data_dispatched) && not !bodiless_body_over_cap
       then (
         let added = String.length line + 1 in
         if Buffer.length bodiless_body + added > max_bodiless_body_bytes
         then bodiless_body_over_cap := true
         else (
           Buffer.add_string bodiless_body line;
           Buffer.add_char bodiless_body '\n')));
    line
  in
  let read_meaningful_line () =
    let rec inner () =
      match parse_sse_line (read_protocol_line ()) with
      | Sse_comment -> inner ()
      | (Sse_blank | Sse_event_type _ | Sse_data _ | Sse_ignored_field) as parsed ->
        parsed
    in
    let budget =
      armed_budget ~phase:!phase ~first_event_timeout ~body_timeout ~idle_timeout
    in
    let parsed =
      match clock, budget with
      | Some c, Some (Gap seconds | Total seconds) ->
        read_within_budget ~clock:c ~anchor:budget_anchor ~seconds inner
      | Some _, None -> inner ()
      (* No clock: nothing can be armed. Misconfiguration (an explicit
         deadline without a clock) already failed loud at entry, so this is
         the no-config default — best-effort read, unchanged pre-timeout
         behaviour. *)
      | None, _ -> inner ()
    in
    (* Nothing renews a budget here. A data field is provider bytes, not model
       output -- a keep-alive carries one, and renewing on it let a provider
       hold an open stream for the whole turn while producing nothing. Only
       the consumer can tell production from a keep-alive, so renewal happens
       per dispatched event in [dispatch_event]: before the first output any
       event renews a gap standing in for the first-event bound, after it only
       production does. A total budget is not renewed at all: it runs to the
       first output whatever arrives in between. *)
    parsed
  in
  let current_event_type = ref None in
  let data_buffer = Buffer.create 256 in
  let data_seen = ref false in
  let dispatch_event () =
    let continuation =
      if !data_seen
      then (
        let continuation =
          on_data ~event_type:!current_event_type (Buffer.contents data_buffer)
        in
        Buffer.clear data_buffer;
        data_seen := false;
        (* The stream has a body now: retention has no reader left, so drop
           what it held rather than carrying it to EOF. *)
        data_dispatched := true;
        Buffer.clear bodiless_body;
        let renew_gap () =
          renew_after_payload
            ~anchor:budget_anchor
            (armed_budget ~phase:!phase ~first_event_timeout ~body_timeout ~idle_timeout)
        in
        let phase_before_dispatch = !phase in
        (match continuation with
         | Continue Output ->
           enter_after_first_output
             ~phase
             ~anchor:budget_anchor
             ~first_event_timeout
             ~body_timeout
             ~idle_timeout;
           (* Production is what an inter-token gap measures between, so this
              is where that gap starts again. [renew_after_payload] leaves a
              total budget alone. *)
           renew_gap ()
         | Continue Prelude ->
           (* Before the first output there is no production to measure
              between: a gap standing in for the first-event bound is the wait
              for the provider to send anything, and any event it sends
              renews it. Demanding production there would turn that gap into a
              total. After the first output the gap measures between
              productions, and a keep-alive is not one. *)
           (match phase_before_dispatch with
            | Before_first_output -> renew_gap ()
            | After_first_output -> ())
         | Stop -> ());
        continuation)
      else Continue Prelude
    in
    current_event_type := None;
    continuation
  in
  let rec loop () =
    match read_meaningful_line () with
    | Sse_blank ->
      (* The blank line is the EventSource dispatch boundary. Multiple data
         fields in one event are joined with a single LF; dispatching each
         field independently would hand a JSON-lines fragment to a parser and
         silently violate the SSE contract. *)
      (* [Stop] ends the read here, before the next blocking read, so the
         consumer's decision and the socket's lifetime are the same event. *)
      (match dispatch_event () with
       | Stop -> ()
       | Continue (Output | Prelude) -> loop ())
    | Sse_comment ->
      (* Filtered inside [read_meaningful_line]. *)
      loop ()
    | Sse_event_type value ->
      (* An empty event field restores the default "message" event type. The
         callback represents that default as [None], matching a missing field. *)
      current_event_type := if String.equal value "" then None else Some value;
      loop ()
    | Sse_data value ->
      (* Charge the join separator too: the bound must cover exactly what
         [dispatch_event] will hand out, and it is checked BEFORE the append so
         the accumulator never holds an over-limit payload. *)
      let added_bytes =
        String.length value
        + if !data_seen then String.length sse_data_join_separator else 0
      in
      let actual_bytes = Buffer.length data_buffer + added_bytes in
      if actual_bytes > max_event_bytes
      then raise (Sse_event_too_large { actual_bytes; limit_bytes = max_event_bytes });
      if !data_seen then Buffer.add_string data_buffer sse_data_join_separator;
      Buffer.add_string data_buffer value;
      (* Empty data is still observed: [data:] sets the data flag even when
         its value is empty, so the blank boundary dispatches an empty
         payload instead of making protocol garbage invisible. *)
      data_seen := true;
      loop ()
    | Sse_ignored_field ->
      (* [id] / [retry] / unknown names, already classified at the parse
         boundary. They do not re-anchor the armed budget. *)
      loop ()
    | exception End_of_file ->
      (* An event without its blank dispatch boundary is incomplete. The
         stream accumulator will fail closed when no terminal marker arrives;
         do not invent a final event at EOF. *)
      (match on_bodiless_body with
       | Some on_bodiless_body
         when not !data_dispatched && not !bodiless_body_over_cap ->
         on_bodiless_body (Buffer.contents bodiless_body)
       | Some _ | None -> ());
      ()
  in
  loop ()
;;

(** Read NDJSON-formatted lines from a reader (one JSON object per line).
    Skips blank lines so a trailing newline does not yield an empty payload.
    Returns normally on [End_of_file].

    When [clock] and [idle_timeout] are both set, a stalled stream raises
    [Eio.Time.Timeout] after [idle_timeout] seconds of silence measured from
    the last non-blank line; a blank line does not renew it.

    Agent Core contract: the wait for the first line the consumer reports as
    [Output] is the time-to-first-event (TTFT / prefill) window. It is bounded
    by [first_event_timeout] when set, otherwise by [body_timeout], and then
    it is one window from the first body read that a blank line or a line
    reported as [Prelude] neither ends nor extends. With neither set it falls
    back to [idle_timeout] (the pre-RFC bound), which keeps its gap meaning,
    and stays unarmed when the caller wired none of them. The idle budget
    arms after that first [Output] (SSE parity, see [armed_budget]). *)
let read_ndjson
      ?clock
      ?idle_timeout
      ?first_event_timeout
      ?body_timeout
      ~reader
      ~on_line
      ()
  =
  let site = "read_ndjson" in
  require_clock_when_idle ~site ~clock ~idle_timeout;
  require_clock_when_first_event ~site ~clock ~first_event_timeout ~body_timeout;
  let phase = ref Before_first_output in
  (* Anchored like [read_sse] (see [armed_budget]); a non-blank line is the
     payload, so a blank line renews no budget. *)
  let budget_anchor = ref None in
  let read_line () =
    let budget =
      armed_budget ~phase:!phase ~first_event_timeout ~body_timeout ~idle_timeout
    in
    let line =
      match clock, budget with
      | Some c, Some (Gap seconds | Total seconds) ->
        read_within_budget ~clock:c ~anchor:budget_anchor ~seconds (fun () ->
          Eio.Buf_read.line reader)
      | Some _, None -> Eio.Buf_read.line reader
      (* No clock: nothing can be armed. See [read_sse] for why this is
         best-effort rather than a loud failure here. *)
      | None, _ -> Eio.Buf_read.line reader
    in
    (match line with
     | "" -> ()
     | _ -> renew_after_payload ~anchor:budget_anchor budget);
    line
  in
  let rec loop () =
    match read_line () with
    | "" -> loop ()
    | line ->
      (match on_line line with
       | Stop -> ()
       | Continue Output ->
         enter_after_first_output
           ~phase
           ~anchor:budget_anchor
           ~first_event_timeout
           ~body_timeout
           ~idle_timeout;
         loop ()
       | Continue Prelude -> loop ())
    | exception End_of_file -> ()
  in
  loop ()
;;

type body_injection_error =
  | Body_not_json
  | Body_not_object

(* No parser message here: Yojson quotes a fragment of the text it rejected,
   and this body is the prompt payload. *)
let body_injection_error_to_string = function
  | Body_not_json -> "request body is not valid JSON"
  | Body_not_object -> "request body is not a JSON object"
;;

(* A body that cannot take the fields is an error for the caller, never a
   silently unchanged request: the provider would otherwise answer a body that
   was not asked to stream. *)
let inject_into_object_body body_str inject =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields -> Ok (Yojson.Safe.to_string (`Assoc (inject fields)))
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
    Error Body_not_object
  | exception Yojson.Json_error _ -> Error Body_not_json
;;

let inject_stream_param body_str =
  inject_into_object_body body_str (fun fields ->
    ("stream", `Bool true) :: List.filter (fun (k, _) -> k <> "stream") fields)
;;

(* OpenAI streaming omits the [usage] object on every chunk unless the
   request sets [stream_options.include_usage = true], at which point the
   provider sends a final SSE chunk carrying [usage] with an empty
   [choices] array. Without this flag, OpenAI-compatible streaming turns
   report zero token usage. Anthropic/Ollama/Gemini carry usage natively
   and must NOT receive this field. Mirrors [inject_stream_param]'s
   JSON-manipulation style: drop any caller-supplied [stream_options]
   before re-adding so the flag cannot be double-injected. *)
let inject_stream_options_include_usage body_str =
  inject_into_object_body body_str (fun fields ->
    ("stream_options", `Assoc [ "include_usage", `Bool true ])
    :: List.filter (fun (k, _) -> k <> "stream_options") fields)
;;

let inject_stream_and_options body_str =
  inject_into_object_body body_str (fun fields ->
    ("stream_options", `Assoc [ "include_usage", `Bool true ])
    :: ("stream", `Bool true)
    :: List.filter (fun (k, _) -> k <> "stream" && k <> "stream_options") fields)
;;

let%test "inject_stream_and_options matches chained param >> options" =
  (* Parity proof: the combined single-pass injector must be byte-identical to
     [inject_stream_param body |> inject_stream_options_include_usage] across
     Assoc variants, pre-existing stream/stream_options, non-json, array, empty. *)
  List.for_all
    (fun body ->
       inject_stream_and_options body
       = Result.bind (inject_stream_param body) inject_stream_options_include_usage)
    [ {|{"model":"glm-4"}|}
    ; {|{"model":"gpt-4","stream":false}|}
    ; {|{"messages":[],"stream_options":{"include_usage":false}}|}
    ; {|{"a":1,"stream":true,"stream_options":{"x":1}}|}
    ; "not json"
    ; {|[1,2,3]|}
    ; ""
    ]
;;

[@@@coverage off]
(* ── catch_network tests ─────────────────────────────── *)

let%test "catch_network maps End_of_file to NetworkError with kind" =
  match catch_network (fun () -> raise End_of_file) with
  | Error (NetworkError { message; kind = End_of_file }) -> message = "End_of_file"
  | Ok _
  | Error
      ( HttpError _
      | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | Unknown )
          }
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

let%test "catch_network re-raises text-only Sys_error" =
  let expected = Sys_error "broken pipe" in
  try
    ignore (catch_network (fun () -> raise expected));
    false
  with
  | caught -> caught == expected
;;

let%test "catch_network re-raises text-only resource exhaustion" =
  let expected = Sys_error "Too many open files" in
  try
    ignore (catch_network (fun () -> raise expected));
    false
  with
  | caught -> caught == expected
;;

let%test "catch_network re-raises text-only Failure resource exhaustion" =
  let expected = Failure "EMFILE" in
  try
    ignore (catch_network (fun () -> raise expected));
    false
  with
  | caught -> caught == expected
;;

let%test "catch_network classifies Unix ECONNREFUSED" =
  match
    catch_network (fun () -> raise (Unix.Unix_error (Unix.ECONNREFUSED, "connect", "")))
  with
  | Error (NetworkError { kind = Connection_refused; _ }) -> true
  | Ok _
  | Error
      ( HttpError _
      | NetworkError
          { message = _
          ; kind =
              ( Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          }
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

let%test "catch_network classifies Unix ETIMEDOUT" =
  match
    catch_network (fun () -> raise (Unix.Unix_error (Unix.ETIMEDOUT, "connect", "")))
  with
  | Error (NetworkError { kind = Timeout; _ }) -> true
  | Ok _
  | Error
      ( HttpError _
      | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          }
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

(* ── classify_unix_error direct tests ──────────────── *)

let%test "classify_unix_error: EMFILE" =
  classify_unix_error Unix.EMFILE = Local_resource_exhaustion
;;

let%test "classify_unix_error: ENFILE" =
  classify_unix_error Unix.ENFILE = Local_resource_exhaustion
;;

let%test "classify_unix_error: ENOBUFS" =
  classify_unix_error Unix.ENOBUFS = Local_resource_exhaustion
;;

let%test "classify_unix_error: EADDRNOTAVAIL" =
  classify_unix_error Unix.EADDRNOTAVAIL = Local_resource_exhaustion
;;

let%test "classify_unix_error: EPIPE is End_of_file" =
  classify_unix_error Unix.EPIPE = End_of_file
;;

let%test "classify_unix_error: ECONNRESET is Connection_reset" =
  classify_unix_error Unix.ECONNRESET = Connection_reset
;;

let%test "classify_unix_error: ENETUNREACH is Dns_failure" =
  classify_unix_error Unix.ENETUNREACH = Dns_failure
;;

let%test "classify_unix_error: EHOSTUNREACH is Dns_failure" =
  classify_unix_error Unix.EHOSTUNREACH = Dns_failure
;;

let%test "oversized response is typed without draining" =
  let source =
    Eio.Flow.string_source (String.make (Api_common.max_response_body + 1) 'x')
  in
  match
    read_response_body
      ~response:(Cohttp.Response.make ())
      ~transport_eof_seen:(ref false)
      source
  with
  | Error (ProviderFailure { kind = Response_body_too_large { limit_bytes }; _ }) ->
    limit_bytes = Api_common.max_response_body
  | Ok _
  | Error
      ( HttpError _
      | NetworkError _
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure
          { kind =
              ( Capacity_exhausted _
              | Hard_quota _
              | Capability_mismatch _
              | Cli_policy_invalid _
              | Cli_startup_failed _
              | Provider_parse_error _
              | Provider_wire_error _
              | Provider_reported_error _
              | Provider_interrupted
              | Empty_completion _
              | Context_overflow _
              | Unknown_provider_failure _ )
          ; message = _
          } ) -> false
;;

(* ── typed Eio classification tests ───────────────────── *)

let eio_exn err = Eio.Exn.create err

let%test "classify_network_exn: typed Eio refused" =
  match
    classify_network_exn
      (eio_exn (Eio.Exn.X (Eio_unix.Unix_error (Unix.ECONNREFUSED, "connect", ""))))
  with
  | Some (NetworkError { kind = Connection_refused; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: typed Eio timeout" =
  match
    classify_network_exn
      (eio_exn (Eio.Exn.X (Eio_unix.Unix_error (Unix.ETIMEDOUT, "connect", ""))))
  with
  | Some (NetworkError { kind = Timeout; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: typed Eio Unix backend resource exhaustion" =
  match
    classify_network_exn
      (eio_exn (Eio.Exn.X (Eio_unix.Unix_error (Unix.EMFILE, "socket", ""))))
  with
  | Some (NetworkError { kind = Local_resource_exhaustion; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: text-only Sys_error is not transport evidence" =
  classify_network_exn (Sys_error "Connection refused") = None
;;

let%test "classify_network_exn: message-only Failure is not transport evidence" =
  classify_network_exn (Failure "Connection refused") = None
;;

let%test "https_init_error_network_kind: empty trust anchors are TLS" =
  https_init_error_network_kind
    (Api_common.Ca_certs_unavailable "ca-certs: empty trust anchors")
  = Tls_error
;;

let%test "https_init_error_network_kind: TLS config remains TLS" =
  https_init_error_network_kind (Api_common.Tls_config_unavailable "unsupported protocol")
  = Tls_error
;;

let%test "classify_network_exn: plain Tls_alert is Tls_error" =
  match classify_network_exn (Tls_eio.Tls_alert Tls.Packet.HANDSHAKE_FAILURE) with
  | Some (NetworkError { kind = Tls_error; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: plain Tls_failure is Tls_error" =
  match classify_network_exn (Tls_eio.Tls_failure (`Fatal `No_application_protocol)) with
  | Some (NetworkError { kind = Tls_error; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: unknown backend printer text does not classify" =
  let module Test_backend = struct
    type Eio.Exn.Backend.t += Tls_socket_closed_test

    let () =
      Eio.Exn.Backend.register_pp (fun f -> function
        | Tls_socket_closed_test ->
          Format.pp_print_string f "TLS_socket_closed";
          true
        | _ -> false)
    ;;
  end
  in
  match
    classify_network_exn (eio_exn (Eio.Exn.X Test_backend.Tls_socket_closed_test))
  with
  | Some (NetworkError { kind = Unknown; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

(* Inline-test-only; the release profile strips the tests that call it. *)
let[@warning "-32"] multiple_io_exn errs =
  let combine acc err =
    let exn = eio_exn err in
    let bt = Printexc.get_callstack 0 in
    Eio.Exn.combine acc (exn, bt)
  in
  match errs with
  | [] -> eio_exn (Eio.Exn.Multiple_io [])
  | err :: errs ->
    fst (List.fold_left combine (eio_exn err, Printexc.get_callstack 0) errs)
;;

let%test "classify_network_exn: Multiple_io prefers non-retryable kind" =
  match
    classify_network_exn
      (multiple_io_exn
         [ Eio.Exn.X (Eio_unix.Unix_error (Unix.ETIMEDOUT, "connect", ""))
         ; Eio.Exn.X (Eio_unix.Unix_error (Unix.EMFILE, "socket", ""))
         ])
  with
  | Some (NetworkError { kind = Local_resource_exhaustion; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: Multiple_io falls back to first known kind" =
  match
    classify_network_exn
      (multiple_io_exn
         [ Eio.Exn.X (Eio_unix.Unix_error (Unix.EPIPE, "write", ""))
         ; Eio.Exn.X (Eio_unix.Unix_error (Unix.ETIMEDOUT, "connect", ""))
         ])
  with
  | Some (NetworkError { kind = End_of_file; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: Multiple_io keeps a leading reset as a known kind" =
  match
    classify_network_exn
      (multiple_io_exn
         [ Eio.Exn.X (Eio_unix.Unix_error (Unix.ECONNRESET, "read", ""))
         ; Eio.Exn.X (Eio_unix.Unix_error (Unix.ECONNREFUSED, "connect", ""))
         ])
  with
  | Some (NetworkError { kind = Connection_reset; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Connection_refused
              | Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: Multiple_io does not prefer a reset over a refusal" =
  match
    classify_network_exn
      (multiple_io_exn
         [ Eio.Exn.X (Eio_unix.Unix_error (Unix.ECONNREFUSED, "connect", ""))
         ; Eio.Exn.X (Eio_unix.Unix_error (Unix.ECONNRESET, "read", ""))
         ])
  with
  | Some (NetworkError { kind = Connection_refused; _ }) -> true
  | Some (HttpError _ | NetworkError
          { message = _
          ; kind =
              ( Dns_failure
              | Tls_error
              | Timeout
              | Local_resource_exhaustion
              | Connection_reset
              | End_of_file
              | Unknown )
          } | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

(* ── read_ndjson idle_timeout tests ──────────────────── *)

let%test "read_ndjson: no clock/idle_timeout preserves default behaviour" =
  Eio_main.run (fun _env ->
    let flow = Eio.Flow.string_source "{\"a\":1}\n{\"b\":2}\n" in
    let reader = Eio.Buf_read.of_flow ~max_size:1024 flow in
    let lines = ref [] in
    read_ndjson ~reader ~on_line:(fun l ->
      lines := l :: !lines;
      Continue Output) ();
    List.rev !lines = [ "{\"a\":1}"; "{\"b\":2}" ])
;;

let%test "read_ndjson: idle_timeout fires when stream stalls mid-read" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  (* Push one line and keep the sink open (never closed, never written
     again) — the second [Eio.Buf_read.line] call will hang. *)
  Eio.Flow.copy_string "{\"a\":1}\n" sink;
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_ndjson ~clock ~idle_timeout:0.05 ~reader ~on_line:(fun _ -> Continue Output) ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* ── read_sse idle_timeout tests ──────────────────────── *)

let%test "read_sse: no clock/idle_timeout preserves default behaviour" =
  Eio_main.run (fun _env ->
    let flow = Eio.Flow.string_source "data: hello\n\ndata: world\n\n" in
    let reader = Eio.Buf_read.of_flow ~max_size:1024 flow in
    let payloads = ref [] in
    read_sse ~reader ~on_data:(fun ~event_type:_ d ->
      payloads := d :: !payloads;
      Continue Output) ();
    List.rev !payloads = [ "hello"; "world" ])
;;

let%test "read_sse: on_bodiless_body fires for a body with no data payload" =
  Eio_main.run (fun _env ->
    let body = {|{"error":{"code":429,"message":"slow down"}}|} in
    let flow = Eio.Flow.string_source (body ^ "\n") in
    let reader = Eio.Buf_read.of_flow ~max_size:1024 flow in
    let data_calls = ref 0 in
    let bodiless = ref None in
    read_sse
      ~reader
      ~on_data:(fun ~event_type:_ _ ->
        incr data_calls;
        Continue Output)
      ~on_bodiless_body:(fun raw -> bodiless := Some raw)
      ();
    !data_calls = 0 && !bodiless = Some (body ^ "\n"))
;;

let%test "read_sse: on_bodiless_body stays silent once data is dispatched" =
  Eio_main.run (fun _env ->
    let flow = Eio.Flow.string_source "data: hello\n\n" in
    let reader = Eio.Buf_read.of_flow ~max_size:1024 flow in
    let data_calls = ref 0 in
    let bodiless_calls = ref 0 in
    read_sse
      ~reader
      ~on_data:(fun ~event_type:_ _ ->
        incr data_calls;
        Continue Output)
      ~on_bodiless_body:(fun _ -> incr bodiless_calls)
      ();
    !data_calls = 1 && !bodiless_calls = 0)
;;

let%test "read_sse: on_bodiless_body never sees a truncated body" =
  Eio_main.run (fun _env ->
    let flow = Eio.Flow.string_source {|{"error":{"code":429,"message":"slow down"}}|} in
    let reader = Eio.Buf_read.of_flow ~max_size:1024 flow in
    let bodiless_calls = ref 0 in
    read_sse
      ~reader
      ~max_bodiless_body_bytes:16
      ~on_data:(fun ~event_type:_ _ -> Continue Output)
      ~on_bodiless_body:(fun _ -> incr bodiless_calls)
      ();
    !bodiless_calls = 0)
;;

let%test "read_sse: idle_timeout fires when stream stalls mid-read" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  Eio.Flow.copy_string "data: hello\n" sink;
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_sse ~clock ~idle_timeout:0.05 ~reader ~on_data:(fun ~event_type:_ _ -> Continue Output) ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* ── Agent Core contract: first_event_timeout (TTFT/prefill) tests ── *)

(* Acceptance (a): a silent prefill that produces its first event AFTER the
   short inter-token idle but WITHIN the first-event budget must succeed —
   NOT be cancelled as a first-token timeout. Reverting the change (using the
   short idle for the first event) makes this test fail: the 0.2s silent
   prefill exceeds the 0.05s idle. *)
let%test "read_sse: first_event_timeout admits a silent prefill past idle" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let payloads = ref [] in
  Eio.Fiber.both
    (fun () ->
       (* Silent for 0.2s: longer than idle (0.05), shorter than the
          first-event budget (1.0). Then emit the first event and close. *)
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "data: hello\n\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       read_sse
         ~clock
         ~idle_timeout:0.05
         ~first_event_timeout:1.0
         ~reader
         ~on_data:(fun ~event_type:_ d ->
      payloads := d :: !payloads;
      Continue Output)
         ());
  List.rev !payloads = [ "hello" ]
;;

(* Acceptance (b): no first event ever arrives — the short first-event budget
   still guards a dead connect even though the inter-token idle budget is
   long. *)
let%test "read_sse: first_event_timeout fires when no first event arrives" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, _sink = Eio_unix.pipe sw in
  (* Keep the sink open and never write: the first line read hangs. The long
     idle budget (1.0) must NOT rescue it; the first-event budget (0.05) does
     the guarding. *)
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_sse
      ~clock
      ~idle_timeout:1.0
      ~first_event_timeout:0.05
      ~reader
      ~on_data:(fun ~event_type:_ _ -> Continue Output)
      ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* Acceptance (c): after the first event, inter-token idle still guards a
   stalled active stream — unchanged behaviour. The first-event budget (1.0)
   is long; the idle budget (0.05) is what fires once the stream has
   produced. *)
let%test "read_sse: idle_timeout still guards after the first event" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  (* The first output event arrives immediately and is dispatched, then the
     stream goes silent. *)
  Eio.Flow.copy_string "data: hello\n\n" sink;
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_sse
      ~clock
      ~idle_timeout:0.05
      ~first_event_timeout:1.0
      ~reader
      ~on_data:(fun ~event_type:_ _ -> Continue Output)
      ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* The consumer, not the transport, says when the stream has produced. A
   Responses stream opens with [response.created] and an Anthropic stream with
   [message_start] before prefill; a reader that switched budgets on that
   first data line put the silent prefill under the short inter-token idle
   (gpt-5.6-luna, 2026-09-10, 164 s: "stream_idle_timeout_s deadline exceeded
   while awaiting_first_delta"). Here the first event is reported as
   [Prelude], the stream is then silent for 0.2 s (> idle 0.05, < first-event
   1.0), and the output event that follows must still be delivered. *)
let%test "read_sse: a prelude event does not end the first-event wait" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let payloads = ref [] in
  Eio.Fiber.both
    (fun () ->
       Eio.Flow.copy_string "data: created\n\n" sink;
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "data: hello\n\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       read_sse
         ~clock
         ~idle_timeout:0.05
         ~first_event_timeout:1.0
         ~reader
         ~on_data:(fun ~event_type:_ d ->
           payloads := d :: !payloads;
           Continue (if String.equal d "created" then Prelude else Output))
         ());
  List.rev !payloads = [ "created"; "hello" ]
;;

(* Control for the test above: the same stream with the same silence times
   out when the consumer reports the opening frame as [Output], and it does so
   under the inter-token idle budget, well before the first-event budget
   would have fired. *)
let%test "read_sse: the first output event ends the first-event wait" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let started = Eio.Time.now clock in
  Eio.Fiber.both
    (fun () ->
       Eio.Flow.copy_string "data: created\n\n" sink;
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "data: hello\n\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       match
         read_sse
           ~clock
           ~idle_timeout:0.05
           ~first_event_timeout:1.0
           ~reader
           ~on_data:(fun ~event_type:_ _ -> Continue Output)
           ()
       with
       | () -> failwith "the inter-token idle budget did not fire"
       | exception Eio.Time.Timeout -> ());
  Eio.Time.now clock -. started < 1.0
;;

(* NDJSON parity: the first line the consumer reports as [Prelude] keeps the
   first-event budget armed, and the output line 0.2 s later is still read. *)
let%test "read_ndjson: a prelude line does not end the first-event wait" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let lines = ref [] in
  Eio.Fiber.both
    (fun () ->
       Eio.Flow.copy_string "{\"created\":true}\n" sink;
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "{\"a\":1}\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       read_ndjson
         ~clock
         ~idle_timeout:0.05
         ~first_event_timeout:1.0
         ~reader
         ~on_line:(fun l ->
           lines := l :: !lines;
           Continue (if String.equal l "{\"created\":true}" then Prelude else Output))
         ());
  List.rev !lines = [ "{\"created\":true}"; "{\"a\":1}" ]
;;

(* NDJSON parity for acceptance (a): the first-event budget must admit a silent
   prefill past idle on the Ollama NDJSON path too (reverting to short idle on
   the first line makes this fail). *)
let%test "read_ndjson: first_event_timeout admits a silent prefill past idle" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let lines = ref [] in
  Eio.Fiber.both
    (fun () ->
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "{\"a\":1}\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       read_ndjson
         ~clock
         ~idle_timeout:0.05
         ~first_event_timeout:1.0
         ~reader
         ~on_line:(fun l ->
           lines := l :: !lines;
           Continue Output)
         ());
  List.rev !lines = [ "{\"a\":1}" ]
;;

(* ── Agent Core contract review: effective first-event bound resolution ── *)

(* The pure resolver is the deterministic seam for the fallback policy and for
   what each fallback means: one test per arm of the precedence chain
   [first_event > body > idle > unarmed], so a reordering, a re-introduced
   built-in default or an idle fallback that stops being a gap fails here
   rather than in a timing-dependent I/O test. The I/O tests below prove that
   a resolved bound actually arms the first-event wait through
   [read_sse]/[read_ndjson]. *)
let%test "armed_budget: explicit first_event wins over body and idle, as a total" =
  armed_budget
    ~phase:Before_first_output
    ~first_event_timeout:(Some 5.0)
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = Some (Total 5.0)
;;

let%test "armed_budget: falls back to body_timeout over idle, as a total" =
  armed_budget
    ~phase:Before_first_output
    ~first_event_timeout:None
    ~body_timeout:(Some 3.0)
    ~idle_timeout:(Some 0.5)
  = Some (Total 3.0)
;;

(* Pre-RFC behaviour preservation: with only an idle deadline wired, that value
   bounded the first event too, as a gap every payload line renews. Widening
   it, or turning it into a total, would be an unrequested behaviour change
   for every such caller. *)
let%test "armed_budget: falls back to idle when it is the only bound, as a gap" =
  armed_budget
    ~phase:Before_first_output
    ~first_event_timeout:None
    ~body_timeout:None
    ~idle_timeout:(Some 0.5)
  = Some (Gap 0.5)
;;

(* Guards the removed provider idle defaults: with nothing wired the resolver
   must stay unarmed rather than invent a bound of its own. *)
let%test "armed_budget: all-None stays unarmed" =
  armed_budget
    ~phase:Before_first_output
    ~first_event_timeout:None
    ~body_timeout:None
    ~idle_timeout:None
  = None
;;

let%test "armed_budget: after the first output only the idle gap is armed" =
  armed_budget
    ~phase:After_first_output
    ~first_event_timeout:(Some 5.0)
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = Some (Gap 0.5)
;;

(* Agent Core contract attribution: a fired deadline must name the knob that supplied
   its value. Pinning all three first-event sources plus one later phase means
   a regression to the old "always stream_idle_timeout_s" message fails here. *)
let%test "governing_timeout_knob: first-event names its explicit knob" =
  governing_timeout_knob
    ~phase:Before_first_output
    ~first_event_timeout:(Some 5.0)
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = First_event_timeout
;;

let%test "governing_timeout_knob: first-event names body when it supplied the bound" =
  governing_timeout_knob
    ~phase:Before_first_output
    ~first_event_timeout:None
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = Body_timeout
;;

let%test "governing_timeout_knob: first-event names idle when idle supplied the bound" =
  governing_timeout_knob
    ~phase:Before_first_output
    ~first_event_timeout:None
    ~body_timeout:None
    ~idle_timeout:(Some 0.5)
  = Stream_idle_timeout
;;

let%test "governing_timeout_knob: after the first output the idle knob governs" =
  governing_timeout_knob
    ~phase:After_first_output
    ~first_event_timeout:(Some 5.0)
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = Stream_idle_timeout
;;

let%test "timeout_knob_to_param: names match the caller-facing parameters" =
  String.equal (timeout_knob_to_param First_event_timeout) "first_event_timeout_s"
  && String.equal (timeout_knob_to_param Body_timeout) "body_timeout_s"
  && String.equal (timeout_knob_to_param Stream_idle_timeout) "stream_idle_timeout_s"
;;

(* P3b (production default): [first_event_timeout = None] + [body_timeout = Some
   small] + a reader that never emits a first event. Pre-fix the first-event
   wait was fully unbounded and this read hung forever (defeating Agent Core contract
   acceptance point (4)); the body_timeout fallback now bounds it. The long
   inter-token idle budget must NOT rescue it — the first-event bound does. *)
let%test "read_sse: body_timeout bounds the first-event wait when first_event is None" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, _sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_sse
      ~clock
      ~idle_timeout:1.0
      ~body_timeout:0.05
      ~reader
      ~on_data:(fun ~event_type:_ _ -> Continue Output)
      ();
    false
  with
  | Eio.Time.Timeout -> true
;;

let%test "read_ndjson: body_timeout bounds the first-event wait when first_event is None" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, _sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_ndjson
      ~clock
      ~idle_timeout:1.0
      ~body_timeout:0.05
      ~reader
      ~on_line:(fun _ -> Continue Output)
      ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* P3a (premature transition): a provider that emits a leading BARE BLANK line
   before real prefill. The blank is a dispatch delimiter, not first output, so
   it must NOT switch to the short inter-token idle budget. Then it is silent
   for 0.2s (> idle 0.05, < first-event 1.0) before the real event. Reverting
   the fix (switching budgets on the blank) arms the 0.05 idle for the
   second read and this times out at 0.05s instead of admitting the prefill. *)
let%test "read_sse: a leading blank line does not end the first-event wait" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let payloads = ref [] in
  Eio.Fiber.both
    (fun () ->
       Eio.Flow.copy_string "\n" sink;
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "data: hello\n\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       read_sse
         ~clock
         ~idle_timeout:0.05
         ~first_event_timeout:1.0
         ~reader
         ~on_data:(fun ~event_type:_ d ->
      payloads := d :: !payloads;
      Continue Output)
         ());
  List.rev !payloads = [ "hello" ]
;;

(* NDJSON parity for P3a: a leading blank line must not end the first-event
   wait on the Ollama NDJSON path either. *)
let%test "read_ndjson: a leading blank line does not end the first-event wait" =
  Eio_main.run
  @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run
  @@ fun sw ->
  let source, sink = Eio_unix.pipe sw in
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  let lines = ref [] in
  Eio.Fiber.both
    (fun () ->
       Eio.Flow.copy_string "\n" sink;
       Eio.Time.sleep clock 0.2;
       Eio.Flow.copy_string "{\"a\":1}\n" sink;
       Eio.Flow.close sink)
    (fun () ->
       read_ndjson
         ~clock
         ~idle_timeout:0.05
         ~first_event_timeout:1.0
         ~reader
         ~on_line:(fun l ->
           lines := l :: !lines;
           Continue Output)
         ());
  List.rev !lines = [ "{\"a\":1}" ]
;;
