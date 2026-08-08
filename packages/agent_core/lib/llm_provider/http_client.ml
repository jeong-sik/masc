(** HTTP client for LLM provider endpoints.

    Wraps Eio + cohttp-eio with TLS. All network and HTTP-level errors
    are captured as {!http_error} so callers do not need [try/with].

    Each synchronous request without a [connection_cache] creates a one-shot
    client and explicitly closes the underlying TCP connection as soon as the
    response body is fully consumed. With a cache, connections are bound to
    the cache's switch and reused until eviction or switch release.

    @since 0.45.0 *)

open Result_syntax

type network_error_kind =
  | Connection_refused
  | Dns_failure
  | Tls_error
  | Timeout
  | Local_resource_exhaustion
  | End_of_file
  | Unknown

type stream_idle_state =
  | Awaiting_first_event
  | Awaiting_first_delta
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown
[@@deriving yojson, show]

type timeout_phase =
  | Admission
  | Queue
  | First_token
  | Wall_clock
  | Capacity_backpressure
  | Http_operation
  | Non_streaming_body
  | Stream_body
  | Stream_idle of stream_idle_state
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
  | Request_body_too_large of
      { actual_bytes : int
      ; limit_bytes : int
      }
  | Response_body_too_large of { limit_bytes : int }
  (* oas#2483: the provider returned a 200 with no deliverable content (no
     thinking, text, or tool_calls). Distinct from a parse error. Preserve the
     typed stop reason so policy remains outside this transport fact. *)
  | Empty_completion of { stop_reason : Types.stop_reason }
  (* oas#2947: provider-reported context-window overflow (e.g. glm 1261),
     kept typed so consumers reach their compaction/shrink path instead of
     seeing a generic invalid-request. *)
  | Context_overflow of { limit : int option }
  | Unknown_provider_failure of { reason : string option }

type http_error =
  | HttpError of
      { code : int
      ; body : string
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
  | Request_body_too_large { actual_bytes; limit_bytes } ->
    Printf.sprintf "request_body_too_large:%d:%d" actual_bytes limit_bytes
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

let request_body_too_large_error ~actual_bytes ~limit_bytes =
  ProviderFailure
    { kind = Request_body_too_large { actual_bytes; limit_bytes }
    ; message =
        Printf.sprintf
          "serialized request body is %d bytes, target limit is %d bytes"
          actual_bytes
          limit_bytes
    }
;;

let stream_idle_state_to_label = function
  | Awaiting_first_event -> "awaiting_first_event"
  | Awaiting_first_delta -> "awaiting_first_delta"
  | Streaming_answer -> "streaming_answer"
  | Streaming_thinking -> "streaming_thinking"
  | Streaming_tool_call -> "streaming_tool_call"
  | Streaming_heartbeat -> "streaming_heartbeat"
  | Streaming_substrate -> "streaming_substrate"
  | Streaming_done -> "streaming_done"
  | Streaming_unknown -> "streaming_unknown"
;;

let timeout_phase_of_stream_idle_state = function
  | Awaiting_first_event | Awaiting_first_delta -> First_token
  | state -> Stream_idle state
;;

let timeout_phase_to_label = function
  | Admission -> "admission"
  | Queue -> "queue"
  | First_token -> "first_token"
  | Wall_clock -> "wall_clock"
  | Capacity_backpressure -> "capacity_backpressure"
  | Http_operation -> "http_operation"
  | Non_streaming_body -> "non_streaming_body"
  | Stream_body -> "stream_body"
  | Stream_idle state ->
    Printf.sprintf "stream_idle:%s" (stream_idle_state_to_label state)
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
  | Bounded (clock, timeout_s) -> Eio.Time.with_timeout_exn clock timeout_s f
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
  | Unix.ECONNRESET -> Connection_refused
  | Unix.EPIPE -> End_of_file
  | Unix.ETIMEDOUT -> Timeout
  | Unix.ENETUNREACH -> Dns_failure
  | Unix.EHOSTUNREACH -> Dns_failure
  | Unix.EMFILE | Unix.ENFILE | Unix.ENOBUFS -> Local_resource_exhaustion
  | Unix.EADDRNOTAVAIL -> Local_resource_exhaustion
  | unclassified_unix_error ->
    let (_ : Unix.error) = unclassified_unix_error in
    Unknown
;;

let parse_uri url =
  try Ok (Uri.of_string url) with
  | Invalid_argument msg ->
    Error
      (NetworkError
         { message = Printf.sprintf "invalid URL %S: %s" url msg; kind = Unknown })
;;

let log_close_failure ~url ~message =
  let json =
    `Assoc
      [ "event", `String "http_client_socket_close_failed"
      ; "url", `String url
      ; "error", `String message
      ]
  in
  Diag.warn "http_client" "%s" (Yojson.Safe.to_string json)
;;

(* Empirically measured (2026-05-31) against RunPod's *.proxy.runpod.net edge:
   a single request header LINE >= 8192 bytes is rejected by the cloudflare edge
   with an opaque "400 Bad Request" (server: cloudflare, empty body, cf-ray)
   BEFORE the request reaches the origin. The binding limit is per-header-line,
   NOT the header total — 20 x 500B headers (10 KB total) passed, while one
   8192B header did not. Body size (up to 2 MB) and malformed header values did
   not reproduce it. *)
let cdn_per_header_limit_bytes = 8192

(* key + ": " + value + CRLF — the on-wire size of one header line. *)
let header_line_bytes (key, value) = String.length key + String.length value + 4

(* Request header size profile (name + on-wire bytes, largest first). VALUES ARE
   OMITTED: header values may carry credentials (Authorization, tokens), so only
   sizes are logged. *)
let header_size_profile headers =
  headers
  |> List.map (fun ((k, _) as h) -> k, header_line_bytes h)
  |> List.sort (fun (_, a) (_, b) -> compare b a)
  |> List.map (fun (k, n) -> `Assoc [ "name", `String k; "bytes", `Int n ])
;;

let max_single_header_bytes headers =
  List.fold_left (fun acc h -> max acc (header_line_bytes h)) 0 headers
;;

(* On a 4xx response, log the request's header size profile and the response's
   edge signature (server, cf-ray). A 4xx with an empty/opaque body and a
   "cloudflare" server indicates an edge rejection — commonly a single header
   line over [cdn_per_header_limit_bytes] — rather than an origin-level error.
   This names the offending header WHEN a real failure recurs: header contents
   are runtime-dependent and not knowable statically, so a pre-send size guess
   either never fires (small headers) or false-fires on benign many-small-header
   requests the edge accepts. *)
let profile_headers_on_client_error ~url ~code ~resp_headers request_headers =
  if code >= 400 && code < 500
  then (
    let server = Http.Header.get resp_headers "server" in
    let cf_ray = Http.Header.get resp_headers "cf-ray" in
    let opt = function
      | Some s -> `String s
      | None -> `Null
    in
    let total =
      List.fold_left (fun acc h -> acc + header_line_bytes h) 0 request_headers
    in
    let json =
      `Assoc
        [ "event", `String "http_client_4xx_request_header_profile"
        ; "url", `String url
        ; "status", `Int code
        ; "response_server", opt server
        ; "cf_ray", opt cf_ray
        ; "request_header_count", `Int (List.length request_headers)
        ; "total_request_header_bytes", `Int total
        ; "max_single_header_bytes", `Int (max_single_header_bytes request_headers)
        ; "cdn_per_header_limit_bytes", `Int cdn_per_header_limit_bytes
        ; "header_sizes", `List (header_size_profile request_headers)
        ; ( "note"
          , `String
              "4xx from an LLM endpoint. Header VALUES omitted (may carry credentials); \
               sizes only. A cloudflare/RunPod edge rejects a single header line over \
               cdn_per_header_limit_bytes with an opaque 400 before the origin — compare \
               max_single_header_bytes." )
        ]
    in
    Diag.warn "http_client" "%s" (Yojson.Safe.to_string json))
;;

(* On a 4xx, the response body from a provider edge is frequently an opaque
   "Bad Request" with no field-level cause (observed 2026-07-18 against
   ollama.com/v1 deepseek-v4-flash: ~78% of turns rejected, empty-detail body).
   The request that provoked it is then lost, because [HttpError] only carries
   the RESPONSE body. This logs a STRUCTURAL profile of the REQUEST body so a
   recurring provider 4xx can be attributed to a request shape without a repro
   harness or a full-body dump.

   Only structural facts are emitted — field presence, counts, message role
   sequence, and enumerable option values (response_format type, reasoning
   effort). Prompt/message TEXT and tool argument values are never logged: they
   may carry user content and do not distinguish an accepted shape from a
   rejected one. A body that is not JSON is reported as such rather than
   parsed. *)
(* Exhaustive over the closed [Yojson.Safe.t] variant — no catch-all, so a
   future Yojson constructor forces a compile update rather than silently
   mislabelling. The label helpers take a [Yojson.Safe.t option] so an ABSENT
   top-level field is distinguished from a present field whose value is [`Null]
   or the wrong type: a missing field and a malformed field are separate
   diagnostic facts, and reporting one as the other makes the profile lie. *)
let string_field_label : Yojson.Safe.t option -> Yojson.Safe.t = function
  | None -> `String "<absent>"
  | Some (`String s) -> `String s
  | Some `Null -> `String "<null>"
  | Some (`Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) ->
    `String "<non-string>"
;;

(* Tri-state length of an optional top-level list field. An empty list and an
   absent field are separate facts (a body with no [messages] key differs from
   one with [messages: []]); a present non-list value is a third. *)
let list_len_field_label : Yojson.Safe.t option -> Yojson.Safe.t = function
  | None -> `String "<absent>"
  | Some (`List xs) -> `Int (List.length xs)
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) ->
    `String "<non-list>"
;;

(* Some providers wrap every function declaration in a single top-level [tools]
   element (Gemini nests them under [functionDeclarations]), so [tool_count] is
   1 regardless of how many declarations it holds. Reveal the nested count
   generically: if the first [tools] element is an object with a list-valued
   field, report that list's length. No provider key is named — any object with
   an inner list qualifies; anything else is [<n/a>]. *)
let first_inner_list_len : Yojson.Safe.t option -> Yojson.Safe.t =
  let inner_len fields =
    List.find_map
      (function
        | _key, `List inner -> Some (List.length inner)
        | _key, (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
          -> None)
      fields
  in
  function
  | Some (`List (`Assoc first :: _)) ->
    (match inner_len first with
     | Some n -> `Int n
     | None -> `String "<n/a>")
  | Some (`List [])
  | Some
      (`List ((`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) :: _))
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
  | None -> `String "<n/a>"
;;

let json_is_present : Yojson.Safe.t -> bool = function
  | `Null -> false
  | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> true
;;

(* A rejected POST body can embed base64 media; parsing it whole on the 4xx
   failure path adds allocation and latency for no diagnostic gain. Above this
   size the parse is skipped and only the byte count is reported. 64 KiB holds a
   text-only chat request (messages, tools, options) while excluding
   media-laden bodies. *)
let max_profiled_body_bytes = 64 * 1024

let request_body_shape_profile (body : string) : Yojson.Safe.t =
  if String.length body > max_profiled_body_bytes
  then
    (* Oversized: skip the full parse. [parseable] is [false] because no parse
       was attempted; [skipped_oversized] records the reason so a consumer does
       not read it as a malformed body. *)
    `Assoc
      [ "parseable", `Bool false
      ; "body_bytes", `Int (String.length body)
      ; "skipped_oversized", `Bool true
      ]
  else (
    match Yojson.Safe.from_string body with
    | exception (Yojson.Json_error _ | Yojson.Safe.Util.Type_error _) ->
      `Assoc [ "parseable", `Bool false; "body_bytes", `Int (String.length body) ]
    | `Assoc fields ->
      let has key = List.mem_assoc key fields in
      (* [field] collapses absent-or-null; [List.assoc_opt] is used directly
         where absent must be told apart from present-null (see the label
         helpers above). *)
      let field key = if has key then List.assoc key fields else `Null in
      let messages_field = List.assoc_opt "messages" fields in
      let role_of_message : Yojson.Safe.t -> Yojson.Safe.t = function
        | `Assoc mfields ->
          (match List.assoc_opt "role" mfields with
           | Some (`String r) -> `String r
           | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
             -> `String "<non-string-role>"
           | None -> `String "<no-role>")
        | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          `String "<non-object>"
      in
      (* Roles are reported only when [messages] is a real list; an absent or
         non-list [messages] carries no role sequence to report. *)
      let message_roles_field =
        match messages_field with
        | Some (`List ms) -> [ "message_roles", `List (List.map role_of_message ms) ]
        | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _)
        | None -> []
      in
      let response_format_type =
        match field "response_format" with
        | `Assoc rf ->
          (match List.assoc_opt "type" rf with
           | Some (`String t) -> `String t
           | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
             -> `String "<non-string-type>"
           | None -> `String "<no-type>")
        | `Null -> `Null
        | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
          `String "<non-object>"
      in
      let stream =
        match field "stream" with
        | `Bool b -> `Bool b
        | `Null | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ | `List _ -> `Null
      in
      (* [List.assoc]/[List.mem_assoc] keep only the first binding, so a body
         with duplicate top-level keys — itself a rejection class — would profile
         as if deduped. Report every key that occurs more than once. *)
      let duplicate_keys =
        let names = List.map fst fields in
        `List
          (List.filter_map
             (fun name ->
                let count = List.length (List.filter (String.equal name) names) in
                if count > 1
                then Some (`Assoc [ "name", `String name; "count", `Int count ])
                else None)
             (List.sort_uniq String.compare names))
      in
      (* Every top-level key NAME present, so a rejection caused by an
         unrecognised or misspelled field is diagnosable even though it is not
         one of the typed fields below. Key names are our own serialisation
         vocabulary (schema), not request TEXT, so this leaks no user content.
         Reporting the full key set also makes the profile schema-agnostic
         rather than a curated per-provider key list: the typed fields are
         richer detail on commonly-relevant keys, not the limit of what is
         seen. *)
      let top_level_keys =
        `List
          (List.map
             (fun name -> `String name)
             (List.sort_uniq String.compare (List.map fst fields)))
      in
      `Assoc
        ([ "parseable", `Bool true
         ; "body_bytes", `Int (String.length body)
         ; "top_level_keys", top_level_keys
         ; "model", string_field_label (List.assoc_opt "model" fields)
         ; "message_count", list_len_field_label messages_field
         ]
         @ message_roles_field
         @ [ "contents_count", list_len_field_label (List.assoc_opt "contents" fields)
           ; "input_count", list_len_field_label (List.assoc_opt "input" fields)
           ; "tool_count", list_len_field_label (List.assoc_opt "tools" fields)
           ; ( "tool_first_inner_count"
             , first_inner_list_len (List.assoc_opt "tools" fields) )
           ; "response_format_type", response_format_type
           ; ( "reasoning_effort"
             , string_field_label (List.assoc_opt "reasoning_effort" fields) )
           ; "thinking_present", `Bool (json_is_present (field "thinking"))
           ; "max_tokens_present", `Bool (has "max_tokens")
           ; "stream", stream
           ; "duplicate_keys", duplicate_keys
           ])
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ ->
      `Assoc
        [ "parseable", `Bool true
        ; "body_bytes", `Int (String.length body)
        ; "top_level", `String "<non-object>"
        ])
;;

(* Companion to [profile_headers_on_client_error]: names the request SHAPE on a
   4xx so an opaque provider "Bad Request" can be diagnosed from the always-on
   log, without enabling body-level debug or reproducing the exact turn. *)
let profile_request_on_client_error ~url ~code ~request_body =
  if code >= 400 && code < 500
  then (
    let json =
      `Assoc
        [ "event", `String "http_client_4xx_request_shape"
        ; "url", `String url
        ; "status", `Int code
        ; "request_shape", request_body_shape_profile request_body
        ; ( "note"
          , `String
              "4xx from an LLM endpoint. Structural request facts only; message and \
               tool-argument TEXT omitted (may carry user content and does not \
               distinguish accepted from rejected shapes)." )
        ]
    in
    Diag.warn "http_client" "%s" (Yojson.Safe.to_string json))
;;

let%test "request_body_shape_profile reports non-json bodies without raising" =
  (* Result is always an [`Assoc]; [member] yields [`Null] for a missing key,
     so no catch-all is needed to read a field. *)
  Yojson.Safe.Util.member "parseable" (request_body_shape_profile "Bad Request")
  = `Bool false
;;

let%test "request_body_shape_profile extracts shape without message text" =
  let body =
    {|{"model":"deepseek-v4-flash","messages":[{"role":"system","content":"secret prompt"},{"role":"user","content":"private"}],"tools":[{"type":"function"}],"response_format":{"type":"json_schema"},"reasoning_effort":"high","thinking":{"type":"enabled"}}|}
  in
  let profile = request_body_shape_profile body in
  let s = Yojson.Safe.to_string profile in
  let contains ~needle haystack =
    let nl = String.length needle
    and hl = String.length haystack in
    let rec loop i =
      if i + nl > hl
      then false
      else if String.sub haystack i nl = needle
      then true
      else loop (i + 1)
    in
    nl = 0 || loop 0
  in
  let field key = Yojson.Safe.Util.member key profile in
  (* structural facts present, message content absent *)
  field "model" = `String "deepseek-v4-flash"
  && field "message_count" = `Int 2
  && field "response_format_type" = `String "json_schema"
  && field "reasoning_effort" = `String "high"
  && field "thinking_present" = `Bool true
  && field "max_tokens_present" = `Bool false
  && (not (contains ~needle:"secret prompt" s))
  && not (contains ~needle:"private" s)
;;

(* The profile reports EVERY top-level key by NAME, so a 4xx caused by an
   unrecognised or misspelled field is diagnosable even though that field is not
   one of the typed fields. Key names are our own serialisation vocabulary
   (schema), not request TEXT, so no value or user content leaks through them. *)
let%test "shape profile surfaces unrecognised top-level keys without their values" =
  let body =
    {|{"model":"m","messages":[{"role":"user","content":"private"}],"unexpected_knob":"leak-me","typo_max_tokens":4}|}
  in
  let profile = request_body_shape_profile body in
  let s = Yojson.Safe.to_string profile in
  let contains ~needle haystack =
    let nl = String.length needle
    and hl = String.length haystack in
    let rec loop i =
      if i + nl > hl
      then false
      else if String.sub haystack i nl = needle
      then true
      else loop (i + 1)
    in
    nl = 0 || loop 0
  in
  let keys =
    match Yojson.Safe.Util.member "top_level_keys" profile with
    | `List xs ->
      List.filter_map
        (function
          | `String s -> Some s
          | _ -> None)
        xs
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _ -> []
  in
  let has_key k = List.mem k keys in
  (* unrecognised keys are visible by NAME ... *)
  has_key "unexpected_knob"
  && has_key "typo_max_tokens"
  && has_key "model"
  && has_key "messages"
  (* ... but their VALUES are not echoed, and message content stays absent *)
  && (not (contains ~needle:"leak-me" s))
  && not (contains ~needle:"private" s)
;;

(* Finding 1: an absent field, a present-null field, and a present-non-string
   field are three distinct facts — the profile must not report an absent field
   as a malformed one. *)
let%test "shape profile distinguishes absent from malformed string fields" =
  let m key j = Yojson.Safe.Util.member key j in
  let absent = request_body_shape_profile {|{"model":"m"}|} in
  let present_null = request_body_shape_profile {|{"reasoning_effort":null}|} in
  let present_int = request_body_shape_profile {|{"reasoning_effort":3}|} in
  m "reasoning_effort" absent = `String "<absent>"
  && m "reasoning_effort" present_null = `String "<null>"
  && m "reasoning_effort" present_int = `String "<non-string>"
  && m "model" absent = `String "m"
  && m "model" present_null = `String "<absent>"
;;

(* Finding 2: absent messages / non-list messages must not both read as an empty
   array; roles are attached only for a real list. *)
let%test "shape profile reports messages presence honestly" =
  let m key j = Yojson.Safe.Util.member key j in
  let absent = request_body_shape_profile {|{"model":"m"}|} in
  let empty = request_body_shape_profile {|{"messages":[]}|} in
  let non_list = request_body_shape_profile {|{"messages":"oops"}|} in
  m "message_count" absent = `String "<absent>"
  && m "message_count" empty = `Int 0
  && m "message_count" non_list = `String "<non-list>"
  && m "message_roles" empty = `List []
  && m "message_roles" absent = `Null (* key omitted -> member is `Null *)
  && m "message_roles" non_list = `Null
;;

(* Finding 3: non-chat containers ([contents] for Gemini, [input] for OpenAI
   Responses) are reported with the same tri-state as [messages]. *)
let%test "shape profile reports contents and input container counts" =
  let m key j = Yojson.Safe.Util.member key j in
  let gemini =
    request_body_shape_profile {|{"contents":[{"role":"user"},{"role":"model"}]}|}
  in
  let responses = request_body_shape_profile {|{"input":[{"type":"message"}]}|} in
  let neither = request_body_shape_profile {|{"model":"m"}|} in
  m "contents_count" gemini = `Int 2
  && m "input_count" gemini = `String "<absent>"
  && m "input_count" responses = `Int 1
  && m "contents_count" neither = `String "<absent>"
  && m "contents_count" responses = `String "<absent>"
;;

(* Finding 4: Gemini wraps all declarations in one top-level [tools] element, so
   [tool_count] is 1; the nested list length is surfaced generically. *)
let%test "shape profile reveals nested function-declaration count" =
  let m key j = Yojson.Safe.Util.member key j in
  let gemini =
    request_body_shape_profile
      {|{"tools":[{"functionDeclarations":[{"name":"a"},{"name":"b"},{"name":"c"}]}]}|}
  in
  let flat = request_body_shape_profile {|{"tools":[{"type":"function"}]}|} in
  let none = request_body_shape_profile {|{"model":"m"}|} in
  m "tool_count" gemini = `Int 1
  && m "tool_first_inner_count" gemini = `Int 3
  && m "tool_first_inner_count" flat = `String "<n/a>"
  && m "tool_count" none = `String "<absent>"
  && m "tool_first_inner_count" none = `String "<n/a>"
;;

(* Finding 5: bodies over [max_profiled_body_bytes] skip the full parse. *)
let%test "shape profile skips parsing oversized bodies" =
  let big = {|{"x":"|} ^ String.make (max_profiled_body_bytes + 1) 'a' ^ {|"}|} in
  let profile = request_body_shape_profile big in
  let m key = Yojson.Safe.Util.member key profile in
  m "skipped_oversized" = `Bool true
  && m "parseable" = `Bool false
  && m "body_bytes" = `Int (String.length big)
;;

(* Finding 6: duplicate top-level keys (a rejection class) are surfaced with
   their occurrence count instead of being silently deduped. *)
let%test "shape profile reports duplicate top-level keys" =
  let m key j = Yojson.Safe.Util.member key j in
  let dup = request_body_shape_profile {|{"model":"a","model":"b","stream":true}|} in
  let clean = request_body_shape_profile {|{"model":"a","stream":true}|} in
  m "duplicate_keys" dup = `List [ `Assoc [ "name", `String "model"; "count", `Int 2 ] ]
  && m "duplicate_keys" clean = `List []
;;

let%test "header_line_bytes = key + value + 4 (\": \" + CRLF)" =
  (* "x-runtime-mcp" = 13, "abc" = 3, + 4 = 20 *)
  header_line_bytes ("x-runtime-mcp", "abc") = 20
;;

let%test "header_size_profile orders the largest header first" =
  match
    header_size_profile
      [ "small", "v"; "big", String.make 100 'x'; "mid", String.make 20 'y' ]
  with
  | `Assoc (("name", `String "big") :: _) :: _ -> true
  | _ -> false
;;

(* The edge checks per-header-line size, not the total. Many small headers whose
   total far exceeds the limit are accepted; only the per-header max matters. *)
let%test "max_single_header_bytes ignores the total, tracks the largest line" =
  let many_small =
    List.init 20 (fun i -> Printf.sprintf "x-h%d" i, String.make 500 'y')
  in
  max_single_header_bytes many_small < cdn_per_header_limit_bytes
;;

let%test "max_single_header_bytes flags a single oversized header line" =
  max_single_header_bytes [ "x-big", String.make 9000 'x' ] > cdn_per_header_limit_bytes
;;

let known_network_error_kind = function
  | Unknown -> None
  | ( Connection_refused
    | Dns_failure
    | Tls_error
    | Timeout
    | Local_resource_exhaustion
    | End_of_file ) as kind -> Some kind
;;

(* For composite errors, prefer kinds that should not be retried (local
   resource exhaustion and TLS errors) over transient network failures.
   This mirrors the severity ordering rather than the retry policy itself. *)
let network_error_kind_is_non_retryable = function
  | Local_resource_exhaustion | Tls_error -> true
  | Connection_refused | Dns_failure | Timeout | End_of_file | Unknown -> false
;;

let classify_eio_backend_error = function
  | Eio_unix.Unix_error (code, _, _) -> Some (classify_unix_error code)
  | _ -> None
;;

let rec classify_eio_error = function
  | Eio.Net.E _ ->
    (* Eio 1.3 exposes the typed network envelope but not the finer constructors
       introduced later. Preserve typed control flow without guessing from text. *)
    Unknown
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
  | _ -> false
;;

let%test "classify_network_exn: non-network exn is None (propagates)" =
  classify_network_exn Not_found = None
;;

let%test "timeout_phase_of_stream_idle_state: Awaiting_first_* -> First_token" =
  (* Prefill (no first chunk yet) must surface as [First_token], never
     [Http_operation]. Guards the phase-accuracy fix. *)
  timeout_phase_of_stream_idle_state Awaiting_first_event = First_token
  && timeout_phase_of_stream_idle_state Awaiting_first_delta = First_token
;;

(** Detect errors caused by local resource exhaustion (port/FD limits).
    Cascading to another provider cannot help — the local machine is
    the bottleneck, not the remote server. *)
let is_local_resource_exhaustion = function
  | NetworkError { kind = Local_resource_exhaustion; _ } -> true
  | TimeoutError _ -> false
  | AcceptRejected _ -> false
  | HttpError _ -> false
  | NetworkError _ -> false
  | ProviderTerminal _ -> false
  | ProviderFailure _ -> false
;;

(* ── Retry-After header parsing (RFC 9110 S10.2.3) ────────── *)

let all_digits s = String.length s > 0 && String.for_all (fun c -> c >= '0' && c <= '9') s
let digits_of_len n s = String.length s = n && all_digits s

let month_of_abbrev = function
  | "Jan" -> Some 1
  | "Feb" -> Some 2
  | "Mar" -> Some 3
  | "Apr" -> Some 4
  | "May" -> Some 5
  | "Jun" -> Some 6
  | "Jul" -> Some 7
  | "Aug" -> Some 8
  | "Sep" -> Some 9
  | "Oct" -> Some 10
  | "Nov" -> Some 11
  | "Dec" -> Some 12
  | _ -> None
;;

(* Days since the Unix epoch (1970-01-01) for a proleptic-Gregorian civil
   date. Howard Hinnant's [days_from_civil] algorithm ("chrono-Compatible
   Low-Level Date Algorithms"); OCaml's stdlib has no [timegm] equivalent,
   so this is the standard hand-rolled replacement. Verified against the
   RFC 9110 example date 1994-11-06 08:49:37 GMT -> epoch 784111777. *)
let days_from_civil ~year ~month ~day =
  let y = if month <= 2 then year - 1 else year in
  let era = (if y >= 0 then y else y - 399) / 400 in
  let yoe = y - (era * 400) in
  let mp = (month + 9) mod 12 in
  let doy = (((153 * mp) + 2) / 5) + day - 1 in
  let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
  (era * 146097) + doe - 719468
;;

(* Strict IMF-fixdate parser (RFC 9110 S5.6.7), e.g.
   ["Sun, 06 Nov 1994 08:49:37 GMT"]. Obsolete HTTP-date forms (RFC 850,
   asctime) are not accepted — real Retry-After emitters use delay-seconds
   almost exclusively, and this codebase does not need to interoperate
   with clients emitting the obsolete forms. Never raises: any deviation
   from the exact grammar returns [None]. *)
let parse_imf_fixdate (s : string) : float option =
  match String.split_on_char ' ' s with
  | [ day_name; day_str; month_str; year_str; time_str; "GMT" ] ->
    let day_name_ok = String.length day_name = 4 && day_name.[3] = ',' in
    if
      (not day_name_ok)
      || (not (digits_of_len 2 day_str))
      || not (digits_of_len 4 year_str)
    then None
    else (
      match month_of_abbrev month_str with
      | None -> None
      | Some month ->
        (match String.split_on_char ':' time_str with
         | [ hh; mm; ss ]
           when digits_of_len 2 hh && digits_of_len 2 mm && digits_of_len 2 ss ->
           let day = int_of_string day_str in
           let year = int_of_string year_str in
           let hour = int_of_string hh in
           let minute = int_of_string mm in
           let second = int_of_string ss in
           (* second <= 60 admits the RFC 9110 leap-second allowance. *)
           if day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60
           then None
           else (
             let days = days_from_civil ~year ~month ~day in
             let epoch_seconds =
               (float_of_int days *. 86400.0)
               +. float_of_int ((hour * 3600) + (minute * 60) + second)
             in
             Some epoch_seconds)
         | _ -> None))
  | _ -> None
;;

let parse_retry_after_seconds ~now (raw : string) : float option =
  let trimmed = String.trim raw in
  if all_digits trimmed
  then (
    match int_of_string_opt trimmed with
    | Some seconds -> Some (float_of_int seconds)
    | None -> None (* overflowed int range; reject rather than guess *))
  else (
    match parse_imf_fixdate trimmed with
    | Some epoch_seconds -> Some (Float.max 0.0 (epoch_seconds -. now))
    | None -> None)
;;

let%test "parse_retry_after_seconds: delay-seconds" =
  parse_retry_after_seconds ~now:1_700_000_000.0 "120" = Some 120.0
;;

let%test "parse_retry_after_seconds: delay-seconds ignores surrounding whitespace" =
  parse_retry_after_seconds ~now:1_700_000_000.0 " 45 " = Some 45.0
;;

let%test "parse_retry_after_seconds: negative delay-seconds is malformed" =
  parse_retry_after_seconds ~now:1_700_000_000.0 "-5" = None
;;

let%test "parse_retry_after_seconds: HTTP-date in the future yields positive delay" =
  (* now is 100s before the RFC 9110 S5.6.7 example date -> a 100s delay. *)
  parse_retry_after_seconds ~now:784111677.0 "Sun, 06 Nov 1994 08:49:37 GMT" = Some 100.0
;;

let%test "parse_retry_after_seconds: HTTP-date in the past clamps to zero" =
  (* now is well after the example date; the naive delay would be
     negative, which must clamp to 0.0 rather than signal "retry in the
     past". *)
  parse_retry_after_seconds ~now:1_700_000_000.0 "Sun, 06 Nov 1994 08:49:37 GMT"
  = Some 0.0
;;

let%test "parse_retry_after_seconds: malformed value yields None" =
  parse_retry_after_seconds ~now:1_700_000_000.0 "not-a-value" = None
;;

let%test "parse_retry_after_seconds: empty value yields None" =
  parse_retry_after_seconds ~now:1_700_000_000.0 "" = None
;;

let%test "parse_retry_after_seconds: RFC 850 obsolete form is rejected" =
  parse_retry_after_seconds ~now:1_700_000_000.0 "Sunday, 06-Nov-94 08:49:37 GMT" = None
;;

(* [Http.Header.get] is case-insensitive per cohttp's contract (mirrors the
   "server"/"cf-ray" lookups in [profile_headers_on_client_error] above). *)
let retry_after_header_of_response_headers resp_headers =
  match Http.Header.get resp_headers "retry-after" with
  | None -> None
  | Some raw -> parse_retry_after_seconds ~now:(Unix.gettimeofday ()) raw
;;

let header_has_token headers name token =
  match Http.Header.get headers name with
  | None -> false
  | Some value ->
    value
    |> String.split_on_char ','
    |> List.exists (fun value ->
      String.equal
        (String.lowercase_ascii (String.trim value))
        (String.lowercase_ascii token))
;;

let valid_single_content_length = function
  | [ value ] ->
    let value = String.trim value in
    (not (String.equal value ""))
    && String.for_all
         (function
           | '0' .. '9' -> true
           | _ -> false)
         value
    && Option.is_some (Int64.of_string_opt value)
  | [] | _ :: _ :: _ -> false
;;

let response_connection_is_reusable ~request_headers response =
  let response_headers = Cohttp.Response.headers response in
  let status = Cohttp.Response.status response |> Cohttp.Code.code_of_status in
  let response_allows_persistence =
    match Cohttp.Response.version response with
    | `HTTP_1_1 -> true
    | `HTTP_1_0 -> header_has_token response_headers "connection" "keep-alive"
    | `Other _ -> false
  in
  let is_upgrade =
    status = 101
    || Option.is_some (Http.Header.get response_headers "upgrade")
    || header_has_token response_headers "connection" "upgrade"
  in
  let response_has_no_body =
    (status >= 100 && status < 200) || status = 204 || status = 304
  in
  let response_framing =
    match
      ( Http.Header.get_multi response_headers "content-length"
      , Http.Header.get_multi response_headers "transfer-encoding" )
    with
    | [], [] -> `Absent
    | content_lengths, [] when valid_single_content_length content_lengths ->
      `Content_length
    | [], _ :: _ ->
      (match Cohttp.Header.get_transfer_encoding response_headers with
       | Cohttp.Transfer.Chunked -> `Final_chunked
       | Cohttp.Transfer.Fixed _ | Cohttp.Transfer.Unknown -> `Invalid)
    | _ -> `Invalid
  in
  let response_is_self_delimited =
    match response_framing with
    | `Content_length | `Final_chunked -> true
    | `Absent -> response_has_no_body
    | `Invalid -> false
  in
  (not is_upgrade)
  && response_allows_persistence
  && response_is_self_delimited
  && (not (header_has_token request_headers "connection" "close"))
  && not (header_has_token response_headers "connection" "close")
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
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  Response_header_evidence fingerprint, retry_after_header
;;

let header_evidence_fingerprint_for_test headers =
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
  }

let%test "Retry-After is captured once with explicit duplicate ambiguity" =
  let capture headers =
    headers |> Http.Header.of_list |> capture_response_header_evidence |> snd
  in
  let retry_after_header = capture [ "Retry-After", "7" ] in
  let response = { status = 429; body = "rate limited"; retry_after_header } in
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

type connection = [ `Close | `Flow | `R | `Shutdown | `W ] Eio.Resource.t

let add_connection_close headers = ("connection", "close") :: headers

let maybe_add_connection_close ?cache headers =
  match cache with
  | Some _ -> headers
  | None -> add_connection_close headers
;;

(* ── Connection cache ──────────────────────────────────────── *)

(** Host identity for connection reuse. The cache intentionally ignores
    path, query, and auth: a connection to the same origin can carry
    requests with different URLs and headers. *)
module Cache_key = struct
  type t =
    { scheme : string
    ; host : string
    ; port : int
    }

  let compare a b =
    match String.compare a.scheme b.scheme with
    | 0 ->
      (match String.compare a.host b.host with
       | 0 -> Int.compare a.port b.port
       | n -> n)
    | n -> n
  ;;

  let default_port_for_scheme scheme =
    match scheme with
    | "https" -> 443
    | _ -> 80
  ;;

  let of_uri uri =
    let scheme = Uri.scheme uri |> Option.value ~default:"http" in
    let host =
      match Uri.host uri with
      | Some "" | None -> "localhost"
      | Some h -> h
    in
    let port = Uri.port uri |> Option.value ~default:(default_port_for_scheme scheme) in
    { scheme; host; port }
  ;;

  let%test "Cache_key.of_uri defaults to https port 443" =
    let key = of_uri (Uri.of_string "https://example.com/path") in
    key.scheme = "https" && key.host = "example.com" && key.port = 443
  ;;

  let%test "Cache_key.of_uri defaults to http port 80" =
    let key = of_uri (Uri.of_string "http://example.com/path") in
    key.scheme = "http" && key.host = "example.com" && key.port = 80
  ;;

  let%test "Cache_key.of_uri preserves explicit port" =
    let key = of_uri (Uri.of_string "https://example.com:8443/path") in
    key.port = 8443
  ;;
end

module Cache_map = Map.Make (Cache_key)

type cache_entry =
  { connection : connection
  ; last_used_at : float
  }

type cache_stats =
  { idle_per_host : (string * int) list
  ; total_idle : int
  ; reuse_count_total : int
  ; create_count_total : int
  }

type cache =
  { sw : Eio.Switch.t
  ; mu : Eio.Mutex.t
  ; max_idle_per_host : int
  ; idle_ttl_seconds : float
  ; mutable entries : cache_entry list Cache_map.t
  ; reuse_count_total : int Atomic.t
  ; create_count_total : int Atomic.t
  ; stop : bool Atomic.t
  ; now : unit -> float
  }

let create_cache ~sw ?clock ?(max_idle_per_host = 8) ?(idle_ttl_seconds = 60.0) () : cache
  =
  if max_idle_per_host < 1
  then invalid_arg "Http_client.create_cache: max_idle_per_host must be >= 1";
  if idle_ttl_seconds <= 0.0
  then invalid_arg "Http_client.create_cache: idle_ttl_seconds must be > 0";
  let cache =
    let now =
      match clock with
      | Some clock -> fun () -> Eio.Time.now clock
      | None -> Unix.gettimeofday
    in
    { sw
    ; mu = Eio.Mutex.create ()
    ; max_idle_per_host
    ; idle_ttl_seconds
    ; entries = Cache_map.empty
    ; reuse_count_total = Atomic.make 0
    ; create_count_total = Atomic.make 0
    ; stop = Atomic.make false
    ; now
    }
  in
  Eio.Switch.on_release sw (fun () ->
    Atomic.set cache.stop true;
    let leftover =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let all =
          Cache_map.fold
            (fun _ entries acc -> List.rev_append entries acc)
            cache.entries
            []
        in
        cache.entries <- Cache_map.empty;
        all)
    in
    Eio.Cancel.protect (fun () ->
      List.iter
        (fun e ->
           try Eio.Resource.close e.connection with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | _ -> ())
        leftover));
  (* Eviction daemon: reap entries past [idle_ttl_seconds] when a clock
     is supplied. A regular infinite fiber would prevent normal switch
     completion, and the release hook that sets [stop] only runs after all
     fibers finish. Without a clock the cache still works; stale entries
     are closed on switch release. *)
  (match clock with
   | Some clock ->
     Eio.Fiber.fork_daemon ~sw (fun () ->
       let rec loop () =
         if Atomic.get cache.stop
         then `Stop_daemon
         else (
           Eio.Time.sleep clock (cache.idle_ttl_seconds /. 2.0);
           let now = cache.now () in
           let expired =
             Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
               let expired = ref [] in
               let remaining =
                 Cache_map.map
                   (List.filter (fun e ->
                      if now -. e.last_used_at > cache.idle_ttl_seconds
                      then (
                        expired := e :: !expired;
                        false)
                      else true))
                   cache.entries
               in
               cache.entries <- remaining;
               !expired)
           in
           Eio.Cancel.protect (fun () ->
             List.iter
               (fun e ->
                  try Eio.Resource.close e.connection with
                  | Eio.Cancel.Cancelled _ as exn -> raise exn
                  | _ -> ())
               expired);
           loop ())
       in
       loop ())
   | None -> ());
  cache
;;

let cache_stats (cache : cache) : cache_stats =
  Eio.Mutex.use_ro cache.mu (fun () ->
    let idle_per_host =
      Cache_map.bindings cache.entries
      |> List.map (fun ({ Cache_key.scheme; host; port }, v) ->
        Printf.sprintf "%s://%s:%d" scheme host port, List.length v)
    in
    let total_idle = List.fold_left (fun acc (_, n) -> acc + n) 0 idle_per_host in
    { idle_per_host
    ; total_idle
    ; reuse_count_total = Atomic.get cache.reuse_count_total
    ; create_count_total = Atomic.get cache.create_count_total
    })
;;

(** Find a warm client for [uri] and remove it from the cache so it is
    owned by the caller. Returns [None] if no entry is available. *)
let cache_take (cache : cache) uri : cache_entry option =
  if Atomic.get cache.stop
  then None
  else (
    let key = Cache_key.of_uri uri in
    Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
      match Cache_map.find_opt key cache.entries with
      | Some (e :: rest) ->
        cache.entries <- Cache_map.add key rest cache.entries;
        Atomic.incr cache.reuse_count_total;
        Some e
      | _ -> None))
;;

(** Park a client back into the cache, or close it if the per-host cap
    is reached. [close] is the entry's own shutdown function. *)
let cache_return (cache : cache) uri (entry : cache_entry) : unit =
  if Atomic.get cache.stop
  then Eio.Resource.close entry.connection
  else (
    let key = Cache_key.of_uri uri in
    let now = cache.now () in
    let entry = { entry with last_used_at = now } in
    let parked =
      Eio.Mutex.use_rw ~protect:true cache.mu (fun () ->
        let existing = Cache_map.find_opt key cache.entries |> Option.value ~default:[] in
        if List.length existing < cache.max_idle_per_host
        then (
          cache.entries <- Cache_map.add key (entry :: existing) cache.entries;
          true)
        else false)
    in
    if not parked then Eio.Resource.close entry.connection)
;;

(** Resolve the origin for [uri] and prepare the TLS wrapper if needed.
    The result is reused by both one-shot clients and cached connections. *)
let resolve_origin net uri =
  let net = (net :> [ `Generic ] Eio.Net.ty Eio.Resource.t) in
  let* host =
    match Uri.host uri with
    | Some host when String.trim host <> "" -> Ok host
    | Some _ | None ->
      Error
        (NetworkError
           { message = Printf.sprintf "invalid URL %S: missing host" (Uri.to_string uri)
           ; kind = Unknown
           })
  in
  let service =
    match Uri.port uri with
    | Some port -> Int.to_string port
    | None -> Uri.scheme uri |> Option.value ~default:"http"
  in
  let* addr =
    try
      match Eio.Net.getaddrinfo_stream ~service net host with
      | ip :: _ -> Ok ip
      | [] ->
        Error
          (NetworkError
             { message = Printf.sprintf "failed to resolve hostname: %s" host
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
    match Uri.scheme uri with
    | Some "https" ->
      let wrap_error reason =
        NetworkError
          { message =
              Printf.sprintf
                "HTTPS requested but TLS not available for %s: %s"
                (Uri.to_string uri)
                (Api_common.https_init_error_to_string reason)
          ; kind = https_init_error_network_kind reason
          }
      in
      let+ wrap = Result.map_error wrap_error (Api_common.make_https_result ()) in
      Some wrap
    | Some "http" | Some _ | None -> Ok None
  in
  Ok (net, addr, tls_wrap)
;;

(** Build a reusable client with explicit lifetime control.
    Returns [Ok (client, close)] where [close] shuts down all transports
    created by this client. The client is NOT bound to any switch; the
    caller decides when to close it or park it in a cache. *)
let make_client ~net ~uri =
  let+ net, addr, tls_wrap = resolve_origin net uri in
  let tracked_transports : connection list Atomic.t = Atomic.make [] in
  let connect ~sw:conn_sw _uri =
    let sock = Eio.Net.connect ~sw:conn_sw net addr in
    let transport : connection =
      match tls_wrap with
      | Some wrap -> (wrap uri sock :> connection)
      | None -> (sock :> connection)
    in
    let rec push () =
      let prev = Atomic.get tracked_transports in
      if Atomic.compare_and_set tracked_transports prev (transport :: prev)
      then ()
      else push ()
    in
    push ();
    Diag.debug
      "http_client"
      "connect: new transport #%d for %s"
      (List.length (Atomic.get tracked_transports))
      (Uri.to_string uri);
    transport
  in
  let client = Cohttp_eio.Client.make_generic connect in
  let close () =
    let transports = Atomic.exchange tracked_transports [] in
    let n = List.length transports in
    if n > 0
    then
      Diag.debug
        "http_client"
        "close: closing %d transport(s) for %s"
        n
        (Uri.to_string uri);
    Eio.Cancel.protect (fun () ->
      List.iter
        (fun t ->
           try
             Eio.Resource.close t;
             Diag.debug "http_client" "transport closed for %s" (Uri.to_string uri)
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
             log_close_failure ~url:(Uri.to_string uri) ~message:(Printexc.to_string exn))
        transports)
  in
  client, close
;;

(** Create a single transport connection bound to [sw]. This is the unit
    stored in the connection cache and reused across requests. *)
let make_connection ~sw ~net ~uri : (connection, http_error) result =
  let* net, addr, tls_wrap = resolve_origin net uri in
  try
    let sock = Eio.Net.connect ~sw net addr in
    let conn : connection =
      match tls_wrap with
      | Some wrap -> (wrap uri sock :> connection)
      | None -> (sock :> connection)
    in
    Diag.debug "http_client" "make_connection: new connection for %s" (Uri.to_string uri);
    Ok conn
  with
  | Eio.Io (err, _) as exn -> Error (network_error_of_eio err exn)
  | Unix.Unix_error (code, _, _) as exn ->
    Error
      (NetworkError { message = Printexc.to_string exn; kind = classify_unix_error code })
  | Failure msg -> Error (unknown_network_error msg)
;;

(** Client wrapper that tracks the socket for explicit close.
    The caller provides the concrete URI so host resolution and TLS
    availability can be checked up front and reported as typed errors. *)
let make_closing_client ~sw ~net ~uri =
  let+ client, close = make_client ~net ~uri in
  Eio.Switch.on_release sw close;
  client
;;

(** Run [f client] with a client obtained either from [cache] or created
    for one request. When [cache] is supplied, a hit reuses a parked
    connection, a miss creates one and parks it on success, and any error
    evicts it. When [cache] is omitted the client is created for a single
    request and closed immediately after [f] returns.

    [f] receives the caller switch and must return an
    [('a, http_error) result]. The wrapper distinguishes [Ok] from [Error]
    for cache lifecycle decisions; exceptions are treated as fatal for the
    connection. *)
let with_client ?cache ~sw ~net ~uri f =
  match cache with
  | None ->
    let* client, close = make_client ~net ~uri in
    Fun.protect
      ~finally:(fun () ->
        try Eio.Cancel.protect close with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Diag.warn
            "http_client"
            "with_client one-shot close failed: %s"
            (Printexc.to_string exn))
      (fun () -> f ~sw client)
  | Some cache ->
    let* conn, was_cached =
      match cache_take cache uri with
      | Some e -> Ok (e.connection, true)
      | None ->
        let+ conn = make_connection ~sw:cache.sw ~net ~uri in
        Atomic.incr cache.create_count_total;
        conn, false
    in
    let client =
      Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> (conn :> _ Eio.Flow.two_way))
    in
    let ok = ref false in
    Fun.protect
      ~finally:(fun () ->
        try
          if !ok
          then cache_return cache uri { connection = conn; last_used_at = 0.0 }
          else Eio.Resource.close conn
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn ->
          Diag.warn
            "http_client"
            "with_client cleanup failed: %s"
            (Printexc.to_string exn))
      (fun () ->
         let* result = f ~sw client in
         ok := true;
         Ok result)
;;

let read_response_body resp_body =
  try
    Ok Eio.Buf_read.(of_flow ~max_size:Api_common.max_response_body resp_body |> take_all)
  with
  | Eio.Buf_read.Buffer_limit_exceeded ->
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
    let* uri = parse_uri url in
    with_client ?cache ~sw ~net ~uri (fun ~sw client ->
      let hdr = Http.Header.of_list (maybe_add_connection_close ?cache headers) in
      with_explicit_deadline deadline (fun () ->
        let resp, resp_body = Cohttp_eio.Client.get ~sw client ~headers:hdr uri in
        let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
        let* body_str = read_response_body resp_body in
        Ok (code, body_str))))
;;

let post_sync ?cache ?clock ?timeout_s ~sw ~net ~url ~headers ~body () =
  let* deadline =
    resolve_explicit_deadline
      ~operation:"post_sync"
      ~parameter:"timeout_s"
      ~clock
      ~timeout_s
  in
  catch_network (fun () ->
    let* uri = parse_uri url in
    with_client ?cache ~sw ~net ~uri (fun ~sw client ->
      (* Explicitly set Content-Length to prevent chunked transfer encoding.
         Ollama's yyjson parser rejects chunked bodies with
         "Value looks like object, but can't find closing '}' symbol". *)
      let headers_with_length =
        ("content-length", string_of_int (String.length body))
        :: maybe_add_connection_close ?cache headers
      in
      let hdr = Http.Header.of_list headers_with_length in
      with_explicit_deadline deadline (fun () ->
        let resp, resp_body =
          Cohttp_eio.Client.post
            ~sw
            client
            ~headers:hdr
            ~body:(Cohttp_eio.Body.of_string body)
            uri
        in
        let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
        profile_headers_on_client_error
          ~url
          ~code
          ~resp_headers:(Cohttp.Response.headers resp)
          headers_with_length;
        profile_request_on_client_error ~url ~code ~request_body:body;
        let* body_str = read_response_body resp_body in
        Ok (code, body_str))))
;;

let post_sync_once_after_validation
      ?cache
      ~connect_deadline
      ~body_deadline
      ~net
      ~uri
      ~header
      ~body
      ()
  =
  Eio.Switch.run
  @@ fun sw ->
  let request_sw =
    match cache with
    | Some cache -> cache.sw
    | None -> sw
  in
  let phase = ref Before_dispatch in
  let status = ref None in
  let connection = ref None in
  let close_connection conn =
    try Eio.Cancel.protect (fun () -> Eio.Resource.close conn) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Diag.warn "http_client" "post_sync_once cleanup failed: %s" (Printexc.to_string exn)
  in
  let fail error =
    match !phase, !status with
    | Before_dispatch, None -> Error (Before_dispatch_error error)
    | Dispatch_started, None -> Error (Dispatch_started_error error)
    | Response_received, Some status -> Error (Response_received_error { status; error })
    | Before_dispatch, Some _ | Dispatch_started, Some _ | Response_received, None ->
      invalid_arg "Http_client.post_sync_once: inconsistent receipt state"
  in
  let release_connection () =
    match !connection with
    | None -> ()
    | Some conn ->
      connection := None;
      close_connection conn
  in
  (* An unclassified exception is still a transport failure, and this function
     returns a result. Re-raising it made the return type a half-truth: cohttp-eio
     signals a peer close with [failwith "connection closed by peer"]
     (cohttp-eio/client.ml:60), classify_network_exn rightly answers [None] for prose
     rather than inventing a network kind, and the exception then escaped every
     caller. Two suites caught it — exact-output single-surface's receipt phase
     matrix and one-dispatch framing's stale-cache case — through different call
     paths, which is the signal that the fix belongs at this single choke point
     rather than at each boundary.

     Reserved exceptions (cancellation) are re-raised first, unchanged.
     [Unknown_provider_failure] states that the failure was not classified instead
     of guessing a kind; the message is diagnostics only, per the note on
     [provider_failure_to_string] telling consumers to branch on the kind and never
     parse the string. *)
  let fail_exn exn =
    match classify_network_exn exn with
    | Some error -> Error error
    | None ->
      release_connection ();
      Reserved_exn.reraise_if_reserved exn;
      Error
        (ProviderFailure
           { kind = Unknown_provider_failure { reason = Some (Printexc.to_string exn) }
           ; message = "unclassified transport exception"
           })
  in
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
      (match Eio.Time.with_timeout clock timeout_s (fun () -> Ok (f ())) with
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
        let* conn =
          match cache with
          | None -> make_connection ~sw:request_sw ~net ~uri
          | Some cache ->
            (match cache_take cache uri with
             | Some entry -> Ok entry.connection
             | None ->
               let+ conn = make_connection ~sw:cache.sw ~net ~uri in
               Atomic.incr cache.create_count_total;
               conn)
        in
        connection := Some conn;
        let client =
          Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> (conn :> _ Eio.Flow.two_way))
        in
        phase := Dispatch_started;
        Http_client_phase_observer.observe Http_client_phase_observer.Dispatch_started;
        let response, response_body =
          Cohttp_eio.Client.post
            ~sw:request_sw
            client
            ~headers:header
            ~body:(Cohttp_eio.Body.of_string body)
            uri
        in
        let response_status =
          Cohttp.Response.status response |> Cohttp.Code.code_of_status
        in
        let response_header_evidence, retry_after_header =
          Cohttp.Response.headers response |> capture_response_header_evidence
        in
        phase := Response_received;
        status := Some response_status;
        Http_client_phase_observer.observe
          (Http_client_phase_observer.Response_received response_status);
        Ok (conn, response, response_body, response_header_evidence, retry_after_header))
    with
    | Eio.Time.Timeout as exn ->
      release_connection ();
      raise exn
    | exn -> fail_exn exn
  in
  match post_result with
  | Error error ->
    release_connection ();
    fail error
  | Ok (conn, response, response_body, response_header_evidence, retry_after_header) ->
    let body_result =
      try
        match body_deadline, total_started_at with
        | Unbounded, None -> read_response_body response_body
        | Bounded (clock, timeout_s), Some (_, started_at) ->
          let elapsed = Eio.Time.now clock -. started_at in
          let remaining = timeout_s -. elapsed in
          if remaining <= 0.0
          then Error (total_deadline_error timeout_s)
          else (
            match
              Eio.Time.with_timeout clock remaining (fun () ->
                Ok (read_response_body response_body))
            with
            | Ok result -> result
            | Error `Timeout -> Error (total_deadline_error timeout_s))
        | Unbounded, Some _ | Bounded _, None ->
          invalid_arg "Http_client.post_sync_once: inconsistent total deadline state"
      with
      | Eio.Time.Timeout as exn ->
        release_connection ();
        raise exn
      | exn -> fail_exn exn
    in
    (match body_result with
     | Error error ->
       release_connection ();
       fail error
     | Ok response_body ->
       let release_result =
         match
           cache, response_connection_is_reusable ~request_headers:header response
         with
         | Some cache, true ->
           (try
              cache_return cache uri { connection = conn; last_used_at = 0.0 };
              connection := None;
              Ok ()
            with
            | exn -> fail_exn exn)
         | Some _, false | None, _ ->
           release_connection ();
           Ok ()
       in
       (match release_result with
        | Error error ->
          release_connection ();
          fail error
        | Ok () ->
          Ok
            ( { status = Option.get !status; body = response_body; retry_after_header }
            , response_header_evidence )))
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
       (match parse_uri url with
        | Error error -> before_dispatch error
        | Ok uri ->
          let header =
            try Ok (Http.Header.of_list headers) with
            | Invalid_argument reason -> Error (AcceptRejected { reason })
          in
          (match header with
           | Error error -> before_dispatch error
           | Ok header ->
             post_sync_once_after_validation
               ?cache
               ~connect_deadline
               ~body_deadline
               ~net
               ~uri
               ~header
               ~body
               ())))
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
  | Ok (response, _) -> Ok response
  | Error error -> Error error
;;

let post_stream ?cache ?clock ?connect_timeout_s ~sw ~net ~url ~headers ~body () =
  let* deadline =
    resolve_explicit_deadline
      ~operation:"post_stream"
      ~parameter:"connect_timeout_s"
      ~clock
      ~timeout_s:connect_timeout_s
  in
  (* Cache is intentionally ignored for the streaming reader variant: the
     returned [Buf_read.t] outlives this function, so we cannot safely park
     the client until consumption finishes. Use [with_post_stream] for
     cache-aware streaming. *)
  ignore cache;
  catch_network (fun () ->
    let* uri = parse_uri url in
    let* client = make_closing_client ~sw ~net ~uri in
    let headers_with_length =
      ("content-length", string_of_int (String.length body))
      :: add_connection_close headers
    in
    let hdr = Http.Header.of_list headers_with_length in
    (* Only the connect + initial response headers are bounded; body
       consumption happens in the returned reader and is the caller's
       responsibility to timebox. *)
    let* resp, resp_body =
      with_explicit_deadline deadline (fun () ->
        Ok
          (Cohttp_eio.Client.post
             ~sw
             client
             ~headers:hdr
             ~body:(Cohttp_eio.Body.of_string body)
             uri))
    in
    match Cohttp.Response.status resp with
    | `OK -> Ok (Eio.Buf_read.of_flow ~max_size:Api_common.max_response_body resp_body)
    | status ->
      let code = Cohttp.Code.code_of_status status in
      let resp_headers = Cohttp.Response.headers resp in
      profile_headers_on_client_error ~url ~code ~resp_headers headers_with_length;
      profile_request_on_client_error ~url ~code ~request_body:body;
      let retry_after_header = retry_after_header_of_response_headers resp_headers in
      let* body_str = read_response_body resp_body in
      Error (HttpError { code; body = body_str; retry_after_header }))
;;

let track_connection_eof connection =
  let eof_seen = ref false in
  let module Flow = struct
    type t = unit

    (* Expose no alternate read path: every transport read must pass through
       [single_read] below so raw EOF cannot bypass the observation. *)
    let read_methods = []

    let single_read () buffer =
      match Eio.Flow.single_read connection buffer with
      | count -> count
      | exception End_of_file ->
        eof_seen := true;
        raise End_of_file
    ;;

    let single_write () buffers = Eio.Flow.single_write connection buffers
    let copy () ~src = Eio.Flow.copy src connection
    let shutdown () command = Eio.Flow.shutdown connection command
  end
  in
  let operations =
    Eio.Resource.handler
      (Eio.Resource.H (Eio.Resource.Close, fun () -> Eio.Resource.close connection)
       :: Eio.Resource.bindings (Eio.Flow.Pi.two_way (module Flow)))
  in
  Eio.Resource.T ((), operations), eof_seen
;;

let with_post_stream
      ?cache
      ?clock
      ?connect_timeout_s
      ?on_response_status
      ~net
      ~url
      ~headers
      ~body
      ~f
      ()
  =
  let* deadline =
    resolve_explicit_deadline
      ~operation:"with_post_stream"
      ~parameter:"connect_timeout_s"
      ~clock
      ~timeout_s:connect_timeout_s
  in
  Eio.Switch.run
  @@ fun sw ->
  (* When a cache is active, bind the transport to the cache's long-lived
     switch so the connection can be reused across requests. Otherwise use
     the per-call switch for one-shot cleanup. *)
  let request_sw =
    match cache with
    | Some c -> c.sw
    | None -> sw
  in
  (* Phase 1a: connect + post + response headers, bounded by
     [connect_timeout_s]. Cohttp_eio.Client.post returns once headers are
     parsed (body is a lazy flow), so wrapping only this stage in
     [catch_network] keeps a connect / header-phase stall as
     [TimeoutError { phase = Http_operation }] without absorbing body-phase
     timeouts (first-token / prefill wait, inter-chunk idle).

     Streaming is handled manually rather than through [with_client] so the
     connection is NOT parked until [f] has fully consumed the reader. *)
  let post_result =
    catch_network (fun () ->
      let* uri = parse_uri url in
      let* conn =
        match cache with
        | None -> make_connection ~sw:request_sw ~net ~uri
        | Some cache ->
          (match cache_take cache uri with
           | Some e -> Ok e.connection
           | None ->
             let+ conn = make_connection ~sw:cache.sw ~net ~uri in
             Atomic.incr cache.create_count_total;
             conn)
      in
      let tracked_conn, transport_eof_seen = track_connection_eof conn in
      let client = Cohttp_eio.Client.make_generic (fun ~sw:_ _uri -> tracked_conn) in
      let headers_with_length =
        ("content-length", string_of_int (String.length body))
        :: maybe_add_connection_close ?cache headers
      in
      let hdr = Http.Header.of_list headers_with_length in
      try
        let* resp, resp_body =
          with_explicit_deadline deadline (fun () ->
            Ok
              (Cohttp_eio.Client.post
                 ~sw:request_sw
                 client
                 ~headers:hdr
                 ~body:(Cohttp_eio.Body.of_string body)
                 uri))
        in
        let status = Cohttp.Response.status resp in
        Option.iter
          (fun observe -> observe (Cohttp.Code.code_of_status status))
          on_response_status;
        match status with
        | `OK ->
          (* EOF proves the body was drained; it does not prove the connection
             may be reused. A response with neither content-length nor chunked
             framing is delimited BY the close, so its EOF arrives precisely
             because the peer went away. The same predicate the synchronous
             path uses answers the second question. *)
          let reusable = response_connection_is_reusable ~request_headers:hdr resp in
          let reader =
            Eio.Buf_read.of_flow ~max_size:Api_common.max_response_body resp_body
          in
          Ok (uri, conn, reusable, transport_eof_seen, reader)
        | status ->
          let code = Cohttp.Code.code_of_status status in
          let resp_headers = Cohttp.Response.headers resp in
          profile_headers_on_client_error ~url ~code ~resp_headers headers_with_length;
          profile_request_on_client_error ~url ~code ~request_body:body;
          let retry_after_header = retry_after_header_of_response_headers resp_headers in
          (match read_response_body resp_body with
           | Ok body_str ->
             Eio.Resource.close conn;
             Error (HttpError { code; body = body_str; retry_after_header })
           | Error err ->
             Eio.Resource.close conn;
             Error err)
      with
      | exn ->
        Eio.Resource.close conn;
        (match classify_network_exn exn with
         | Some e -> Error e
         | None -> raise exn))
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
  let* uri, conn, response_is_reusable, transport_eof_seen, reader = post_result in
  let body_result =
    try Ok (f reader) with
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
    | exn ->
      (match classify_network_exn exn with
       | Some e -> Error e
       | None ->
         (* Unclassified exceptions (including cancellation) escape, so close
              the connection before re-raising to avoid leaking a cached socket
              bound to the long-lived cache switch. *)
         Eio.Cancel.protect (fun () -> Eio.Resource.close conn);
         raise exn)
  in
  (match body_result, cache with
   | Ok _, Some cache
     when response_is_reusable && Eio.Buf_read.eof_seen reader && not !transport_eof_seen
     -> cache_return cache uri { connection = conn; last_used_at = 0.0 }
   | Ok _, Some _ | Ok _, None -> Eio.Resource.close conn
   | Error _, _ -> Eio.Resource.close conn);
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
  | Some '\n' ->
    Eio.Buf_read.char '\n' reader;
    line
  | Some '\r' ->
    Eio.Buf_read.char '\r' reader;
    (match Eio.Buf_read.peek_char reader with
     | Some '\n' -> Eio.Buf_read.char '\n' reader
     | Some _ | None -> ());
    line
  | Some _ -> assert false
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

(* RFC-OAS-037: same fail-loud contract for the first-event (TTFT/prefill)
   deadline. Either an explicit [first_event_timeout] OR the [body_timeout]
   fallback that now backs it (see [resolve_first_event_timeout]) would
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

(* RFC-OAS-037: the caller-supplied knob a streaming deadline came from.
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

(* RFC-OAS-037 §4.2: resolve the effective first-event (TTFT/prefill) bound.
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

let resolve_first_event_timeout ~first_event_timeout ~body_timeout ~idle_timeout =
  match resolve_first_event_bound ~first_event_timeout ~body_timeout ~idle_timeout with
  | Bounded { seconds; _ } -> Some seconds
  | Unarmed -> None
;;

(* RFC-OAS-037: name the knob whose value produced the deadline that fired, so
   an operator tunes the budget that actually governs. Derived from the SAME
   resolver as the armed bound — the precedence chain exists in exactly one
   place, so the message can never drift from the behaviour. Only the
   first-event phase can be governed by something other than the idle knob;
   every later phase is inter-token idle by construction. *)
let governing_timeout_knob ~state ~first_event_timeout ~body_timeout ~idle_timeout =
  match state with
  | Awaiting_first_event ->
    (match resolve_first_event_bound ~first_event_timeout ~body_timeout ~idle_timeout with
     | Bounded { knob; _ } -> knob
     | Unarmed -> Stream_idle_timeout)
  | Awaiting_first_delta
  | Streaming_answer
  | Streaming_thinking
  | Streaming_tool_call
  | Streaming_heartbeat
  | Streaming_substrate
  | Streaming_done
  | Streaming_unknown -> Stream_idle_timeout
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
      ~reader
      ~on_data
      ()
  =
  let site = "read_sse" in
  if max_event_bytes <= 0 then invalid_arg "read_sse: max_event_bytes must be positive";
  require_clock_when_idle ~site ~clock ~idle_timeout;
  require_clock_when_first_event ~site ~clock ~first_event_timeout ~body_timeout;
  (* SSE keepalive comments carry no payload. Skipping them inside the
     SAME [with_timeout_exn] window preserves the armed deadline so a
     provider that emits only keepalives still trips it when no real event
     arrives.
     RFC-OAS-037: the wait for the FIRST meaningful line is the
     time-to-first-event (TTFT / prefill) window; bound it with
     [first_event_timeout] (a separate, larger liveness budget) rather than
     the short [idle_timeout], which arms only AFTER the first event for
     inter-token idle. A silent prefill on a large context is slow-but-alive,
     not a hang, so it must not be cut by the inter-token idle value. When
     [first_event_timeout] is [None] the first-event wait falls back to
     [body_timeout] (the total body budget already wired by the caller), then to [idle_timeout] — the
     pre-RFC bound, kept so callers that wired only an idle deadline keep
     exactly their previous behaviour (see [resolve_first_event_timeout]).
     With nothing wired the wait stays unarmed, as before. Inter-token idle
     still guards once the stream produces. *)
  let first_event_seen = ref false in
  (* The armed budget is anchored to the last PAYLOAD-bearing line, not to the
     last line read. Comments are consumed inside one window for exactly this
     reason; [id]/[retry]/unknown fields and bare dispatch delimiters carry no
     payload either, and a per-read window lets a provider hold the stream open
     forever by emitting one ignorable line just under each budget. A blank
     delimiter cannot simply be swallowed inside the window — it must still
     reach [loop] to dispatch and to reset the event type — so the anchor, not
     the filter, is what closes that shape. An [event] field selects a type but
     carries nothing, so it re-anchors only where it ends the first-event wait:
     there the governing budget itself switches from the first-event window to
     inter-token idle, and an anchor left at stream start would fire a spurious
     timeout. *)
  let budget_anchor = ref None in
  let first_line = ref true in
  let read_protocol_line () =
    let line = read_sse_line reader in
    if !first_line
    then (
      first_line := false;
      strip_initial_utf8_bom line)
    else line
  in
  let read_meaningful_line () =
    let rec inner () =
      match parse_sse_line (read_protocol_line ()) with
      | Sse_comment -> inner ()
      | (Sse_blank | Sse_event_type _ | Sse_data _ | Sse_ignored_field) as parsed ->
        parsed
    in
    let active_timeout =
      if !first_event_seen
      then idle_timeout
      else resolve_first_event_timeout ~first_event_timeout ~body_timeout ~idle_timeout
    in
    let parsed =
      match clock, active_timeout with
      | Some c, Some budget ->
        let anchored_at =
          match !budget_anchor with
          | Some t -> t
          | None ->
            let t = Eio.Time.now c in
            budget_anchor := Some t;
            t
        in
        let remaining = anchored_at +. budget -. Eio.Time.now c in
        (* Already past the deadline: raise what [with_timeout_exn] would,
           rather than arming a non-positive duration and depending on a
           scheduler race to produce it. *)
        if Float.compare remaining 0. <= 0
        then raise Eio.Time.Timeout
        else Eio.Time.with_timeout_exn c remaining inner
      | Some _, None -> inner ()
      (* No clock: nothing can be armed. Misconfiguration (an explicit
         deadline without a clock) already failed loud at entry, so this is
         the no-config default — best-effort read, unchanged pre-timeout
         behaviour. *)
      | None, _ -> inner ()
    in
    (* P3a (RFC-OAS-037 review): the transition to the inter-token idle budget
       must fire on GENUINE first output — a data field — NOT on a bare event
       type, blank dispatch delimiter, or other metadata. An [event] field
       selects the dispatch type but carries no payload; counting it as the
       first event would replace the caller's first-event bound with the
       shorter inter-token bound before any provider data arrived.
       [Sse_comment] is already filtered inside [inner]; the only non-field
       line [inner] can return is [Sse_blank]. *)
    (match parsed with
     | Sse_data _ when not !first_event_seen ->
       first_event_seen := true;
       budget_anchor := None
     | Sse_data _ -> budget_anchor := None
     | Sse_event_type _ | Sse_blank | Sse_ignored_field -> ()
     | Sse_comment -> () (* unreachable: filtered in [inner] *));
    parsed
  in
  let current_event_type = ref None in
  let data_buffer = Buffer.create 256 in
  let data_seen = ref false in
  let dispatch_event () =
    if !data_seen
    then (
      on_data ~event_type:!current_event_type (Buffer.contents data_buffer);
      Buffer.clear data_buffer;
      data_seen := false);
    current_event_type := None
  in
  let rec loop () =
    match read_meaningful_line () with
    | Sse_blank ->
      (* The blank line is the EventSource dispatch boundary. Multiple data
         fields in one event are joined with a single LF; dispatching each
         field independently would hand a JSON-lines fragment to a parser and
         silently violate the SSE contract. *)
      dispatch_event ();
      loop ()
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
      ()
  in
  loop ()
;;

(** Read NDJSON-formatted lines from a reader (one JSON object per line).
    Skips blank lines so a trailing newline does not yield an empty payload.
    Returns normally on [End_of_file].

    When [clock] and [idle_timeout] are both set, each line read is
    wrapped in [Eio.Time.with_timeout_exn] so a stalled stream raises
    [Eio.Time.Timeout] after [idle_timeout] seconds of silence.

    RFC-OAS-037: the wait for the FIRST line is the time-to-first-event
    (TTFT / prefill) window, bounded by [first_event_timeout] when set;
    otherwise it falls back to [body_timeout], then to [idle_timeout] (the
    pre-RFC bound), and stays unarmed when the caller wired none of them.
    [idle_timeout] arms only AFTER the first line for inter-token idle. *)
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
  let first_event_seen = ref false in
  let read_line () =
    let active_timeout =
      if !first_event_seen
      then idle_timeout
      else resolve_first_event_timeout ~first_event_timeout ~body_timeout ~idle_timeout
    in
    let line =
      match clock, active_timeout with
      | Some c, Some t ->
        Eio.Time.with_timeout_exn c t (fun () -> Eio.Buf_read.line reader)
      | Some _, None -> Eio.Buf_read.line reader
      (* No clock: nothing can be armed. See [read_sse] for why this is
         best-effort rather than a loud failure here. *)
      | None, _ -> Eio.Buf_read.line reader
    in
    (* P3a (RFC-OAS-037 review): a bare blank line is a delimiter, not real
       provider output — the [loop] below skips it. Flip to the inter-token
       idle budget only on a non-empty line so a leading blank does not switch
       budgets prematurely (SSE [Sse_blank] parity). *)
    if String.length line > 0 then first_event_seen := true;
    line
  in
  let rec loop () =
    match read_line () with
    | "" -> loop ()
    | line ->
      on_line line;
      loop ()
    | exception End_of_file -> ()
  in
  loop ()
;;

let inject_stream_param body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields ->
    let without_existing = List.filter (fun (k, _) -> k <> "stream") fields in
    Yojson.Safe.to_string (`Assoc (("stream", `Bool true) :: without_existing))
  | other -> Yojson.Safe.to_string other
  | exception Yojson.Json_error _ -> body_str
;;

(* OpenAI streaming omits the [usage] object on every chunk unless the
   request sets [stream_options.include_usage = true], at which point the
   provider sends a final SSE chunk carrying [usage] with an empty
   [choices] array. Without this flag, OpenAI-compatible streaming turns
   report zero token usage. Anthropic/Ollama/Gemini carry usage natively
   and must NOT receive this field. Mirrors [inject_stream_param]'s
   JSON-manipulation style: drop any caller-supplied [stream_options]
   before re-adding so the flag cannot be double-injected, and leave a
   malformed/non-object body untouched. *)
let inject_stream_options_include_usage body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields ->
    let without_existing = List.filter (fun (k, _) -> k <> "stream_options") fields in
    Yojson.Safe.to_string
      (`Assoc
          (("stream_options", `Assoc [ "include_usage", `Bool true ]) :: without_existing))
  | other -> Yojson.Safe.to_string other
  | exception Yojson.Json_error _ -> body_str
;;

let inject_stream_and_options body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields ->
    let without_existing =
      List.filter (fun (k, _) -> k <> "stream" && k <> "stream_options") fields
    in
    Yojson.Safe.to_string
      (`Assoc
          (("stream_options", `Assoc [ "include_usage", `Bool true ])
           :: ("stream", `Bool true)
           :: without_existing))
  | other -> Yojson.Safe.to_string other
  | exception Yojson.Json_error _ -> body_str
;;

let%test "inject_stream_and_options matches chained param >> options" =
  (* Parity proof: the combined single-pass injector must be byte-identical to
     [inject_stream_param body |> inject_stream_options_include_usage] across
     Assoc variants, pre-existing stream/stream_options, non-json, array, empty. *)
  List.for_all
    (fun body ->
       inject_stream_and_options body
       = inject_stream_options_include_usage (inject_stream_param body))
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
      | NetworkError _
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
      | NetworkError _
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
      | NetworkError _
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

let%test "classify_unix_error: ECONNRESET is Connection_refused" =
  classify_unix_error Unix.ECONNRESET = Connection_refused
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
  match read_response_body source with
  | Error (ProviderFailure { kind = Response_body_too_large { limit_bytes }; _ }) ->
    limit_bytes = Api_common.max_response_body
  | Ok _
  | Error
      ( HttpError _
      | NetworkError _
      | TimeoutError _
      | AcceptRejected _
      | ProviderTerminal _
      | ProviderFailure _ ) -> false
;;

(* ── is_local_resource_exhaustion tests ──────────────── *)

let%test "resource exhaustion: EADDRNOTAVAIL via Eio" =
  is_local_resource_exhaustion
    (NetworkError
       { message =
           "Eio.Io Unix_error (Can't assign requested address, \"connect\", \"\"), \
            connecting to tcp:128.14.69.121:443"
       ; kind = Local_resource_exhaustion
       })
;;

let%test "resource exhaustion: too many open files" =
  is_local_resource_exhaustion
    (NetworkError { message = "Too many open files"; kind = Local_resource_exhaustion })
;;

let%test "resource exhaustion: EMFILE constant" =
  is_local_resource_exhaustion
    (NetworkError
       { message = "Unix.Unix_error(Unix.EMFILE, \"socket\", \"\")"
       ; kind = Local_resource_exhaustion
       })
;;

let%test "resource exhaustion: ENOBUFS" =
  is_local_resource_exhaustion
    (NetworkError
       { message = "No buffer space available"; kind = Local_resource_exhaustion })
;;

let%test "resource exhaustion: ENFILE constant" =
  is_local_resource_exhaustion
    (NetworkError
       { message = "Unix.Unix_error(Unix.ENFILE, \"socket\", \"\")"
       ; kind = Local_resource_exhaustion
       })
;;

let%test "resource exhaustion: normal connection refused is not" =
  not
    (is_local_resource_exhaustion
       (NetworkError { message = "Connection refused"; kind = Connection_refused }))
;;

let%test "resource exhaustion: HTTP error is not" =
  not
    (is_local_resource_exhaustion
       (HttpError { code = 500; body = "internal"; retry_after_header = None }))
;;

let%test "resource exhaustion: DNS failure is not" =
  not
    (is_local_resource_exhaustion
       (NetworkError
          { message = "failed to resolve hostname: example.com"; kind = Dns_failure }))
;;

(* ── typed Eio classification tests ───────────────────── *)

let eio_exn err = Eio.Exn.create err

let%test "classify_network_exn: typed Eio refused" =
  match
    classify_network_exn
      (eio_exn (Eio.Exn.X (Eio_unix.Unix_error (Unix.ECONNREFUSED, "connect", ""))))
  with
  | Some (NetworkError { kind = Connection_refused; _ }) -> true
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: typed Eio timeout" =
  match
    classify_network_exn
      (eio_exn (Eio.Exn.X (Eio_unix.Unix_error (Unix.ETIMEDOUT, "connect", ""))))
  with
  | Some (NetworkError { kind = Timeout; _ }) -> true
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: typed Eio Unix backend resource exhaustion" =
  match
    classify_network_exn
      (eio_exn (Eio.Exn.X (Eio_unix.Unix_error (Unix.EMFILE, "socket", ""))))
  with
  | Some (NetworkError { kind = Local_resource_exhaustion; _ }) -> true
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
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
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let%test "classify_network_exn: plain Tls_failure is Tls_error" =
  match classify_network_exn (Tls_eio.Tls_failure (`Fatal `No_application_protocol)) with
  | Some (NetworkError { kind = Tls_error; _ }) -> true
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
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
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

let multiple_io_exn errs =
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
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
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
  | Some (HttpError _ | NetworkError _ | TimeoutError _ | AcceptRejected _)
  | Some (ProviderTerminal _ | ProviderFailure _)
  | None -> false
;;

(* ── read_ndjson idle_timeout tests ──────────────────── *)

let%test "read_ndjson: no clock/idle_timeout preserves default behaviour" =
  Eio_main.run (fun _env ->
    let flow = Eio.Flow.string_source "{\"a\":1}\n{\"b\":2}\n" in
    let reader = Eio.Buf_read.of_flow ~max_size:1024 flow in
    let lines = ref [] in
    read_ndjson ~reader ~on_line:(fun l -> lines := l :: !lines) ();
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
    read_ndjson ~clock ~idle_timeout:0.05 ~reader ~on_line:(fun _ -> ()) ();
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
    read_sse ~reader ~on_data:(fun ~event_type:_ d -> payloads := d :: !payloads) ();
    List.rev !payloads = [ "hello"; "world" ])
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
    read_sse ~clock ~idle_timeout:0.05 ~reader ~on_data:(fun ~event_type:_ _ -> ()) ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* ── RFC-OAS-037: first_event_timeout (TTFT/prefill) tests ── *)

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
         ~on_data:(fun ~event_type:_ d -> payloads := d :: !payloads)
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
      ~on_data:(fun ~event_type:_ _ -> ())
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
  (* First event arrives immediately, then the stream goes silent. *)
  Eio.Flow.copy_string "data: hello\n" sink;
  let reader = Eio.Buf_read.of_flow ~max_size:1024 source in
  try
    read_sse
      ~clock
      ~idle_timeout:0.05
      ~first_event_timeout:1.0
      ~reader
      ~on_data:(fun ~event_type:_ _ -> ())
      ();
    false
  with
  | Eio.Time.Timeout -> true
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
         ~on_line:(fun l -> lines := l :: !lines)
         ());
  List.rev !lines = [ "{\"a\":1}" ]
;;

(* ── RFC-OAS-037 review: effective first-event bound resolution ── *)

(* The pure resolver is the deterministic seam for the fallback policy: one
   test per arm of the precedence chain
   [first_event > body > idle > unarmed], so a reordering or a re-introduced
   built-in default fails here rather than in a timing-dependent I/O test. The
   I/O tests below prove that a resolved bound actually arms the first-event
   wait through [read_sse]/[read_ndjson]. *)
let%test "resolve_first_event_timeout: explicit first_event wins over body and idle" =
  resolve_first_event_timeout
    ~first_event_timeout:(Some 5.0)
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = Some 5.0
;;

let%test "resolve_first_event_timeout: falls back to body_timeout over idle" =
  resolve_first_event_timeout
    ~first_event_timeout:None
    ~body_timeout:(Some 3.0)
    ~idle_timeout:(Some 0.5)
  = Some 3.0
;;

(* Pre-RFC behaviour preservation: with only an idle deadline wired, that value
   bounded the first event too. Widening it here would be an unrequested
   behaviour change for every such caller. *)
let%test "resolve_first_event_timeout: falls back to idle when it is the only bound" =
  resolve_first_event_timeout
    ~first_event_timeout:None
    ~body_timeout:None
    ~idle_timeout:(Some 0.5)
  = Some 0.5
;;

(* Guards the removed provider idle defaults: with nothing wired the resolver
   must stay unarmed rather than invent a bound of its own. *)
let%test "resolve_first_event_timeout: all-None stays unarmed" =
  resolve_first_event_timeout
    ~first_event_timeout:None
    ~body_timeout:None
    ~idle_timeout:None
  = None
;;

(* RFC-OAS-037 attribution: a fired deadline must name the knob that supplied
   its value. Pinning all three first-event sources plus one later phase means
   a regression to the old "always stream_idle_timeout_s" message fails here. *)
let%test "governing_timeout_knob: first-event names its explicit knob" =
  governing_timeout_knob
    ~state:Awaiting_first_event
    ~first_event_timeout:(Some 5.0)
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = First_event_timeout
;;

let%test "governing_timeout_knob: first-event names body when it supplied the bound" =
  governing_timeout_knob
    ~state:Awaiting_first_event
    ~first_event_timeout:None
    ~body_timeout:(Some 9.0)
    ~idle_timeout:(Some 0.5)
  = Body_timeout
;;

let%test "governing_timeout_knob: first-event names idle when idle supplied the bound" =
  governing_timeout_knob
    ~state:Awaiting_first_event
    ~first_event_timeout:None
    ~body_timeout:None
    ~idle_timeout:(Some 0.5)
  = Stream_idle_timeout
;;

let%test "governing_timeout_knob: inter-token phases stay attributed to idle" =
  governing_timeout_knob
    ~state:Streaming_answer
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
   wait was fully unbounded and this read hung forever (defeating RFC-OAS-037
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
      ~on_data:(fun ~event_type:_ _ -> ())
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
      ~on_line:(fun _ -> ())
      ();
    false
  with
  | Eio.Time.Timeout -> true
;;

(* P3a (premature transition): a provider that emits a leading BARE BLANK line
   before real prefill. The blank is a dispatch delimiter, not first output, so
   it must NOT switch to the short inter-token idle budget. Then it is silent
   for 0.2s (> idle 0.05, < first-event 1.0) before the real event. Reverting
   the fix (flipping [first_event_seen] on the blank) arms the 0.05 idle for the
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
         ~on_data:(fun ~event_type:_ d -> payloads := d :: !payloads)
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
         ~on_line:(fun l -> lines := l :: !lines)
         ());
  List.rev !lines = [ "{\"a\":1}" ]
;;
