(** Structured provider/API error evidence and typed classification. *)

type invalid_request_reason =
  | Json_parse_error
  | Attempt_rejected
  | Request_body_refused_by_provider of { status : int }
  | Refusal_body_not_received
  | Unknown_invalid_request
  | Unclassified_status of { status : int }

type input_capacity_reason =
  | Serving_constraint_rejected of Serving_constraint.admission_error
  | Token_measurement_unavailable of Input_token_count.protocol

type api_error =
  | RateLimited of
      { retry_after : float option
      ; message : string
      }
  | Overloaded of { message : string }
  | ServerError of
      { status : int
      ; message : string
      }
  | AuthError of { message : string }
  | AuthorizationError of { message : string }
  | PaymentRequired of { message : string }
  | InvalidRequest of
      { message : string
      ; reason : invalid_request_reason
      }
  | NotFound of { message : string }
  | ContextOverflow of
      { message : string
      ; limit : int option
      }
  | InputCapacity of
      { message : string
      ; constraint_ : Serving_constraint.t
      ; reason : input_capacity_reason
      }
  | NetworkError of
      { message : string
      ; kind : Http_client.network_error_kind
      }
  | Connect_failed of
      { message : string
      ; kind : Http_client.network_error_kind
      }
  | Timeout of
      { message : string
      ; phase : Http_client.timeout_phase option
      }

type server_status_class =
  | Overloaded_status
  | Server_error_status

let server_status_class_of_code = function
  | 529 -> Some Overloaded_status
  | status when status >= 500 && status <= 599 -> Some Server_error_status
  | _ -> None
;;

let invalid_request_reason_to_string = function
  | Json_parse_error -> "json_parse_error"
  | Attempt_rejected -> "attempt_rejected"
  | Request_body_refused_by_provider { status } ->
    Printf.sprintf "request_body_refused_by_provider(status=%d)" status
  | Refusal_body_not_received -> "refusal_body_not_received"
  | Unknown_invalid_request -> "unknown"
  | Unclassified_status { status } -> Printf.sprintf "unclassified_status(status=%d)" status
;;

let error_message = function
  | RateLimited r ->
    let retry_after =
      match r.retry_after with
      | None -> " (retry_after: none)"
      | Some seconds -> Printf.sprintf " (retry_after: %.3fs)" seconds
    in
    Printf.sprintf "Rate limited: %s%s" r.message retry_after
  | Overloaded r -> Printf.sprintf "Overloaded: %s" r.message
  | ServerError r -> Printf.sprintf "Server error %d: %s" r.status r.message
  | AuthError r -> Printf.sprintf "Auth error: %s" r.message
  | AuthorizationError r -> Printf.sprintf "Authorization error: %s" r.message
  | PaymentRequired r -> Printf.sprintf "Payment required: %s" r.message
  | InvalidRequest r ->
    Printf.sprintf
      "Invalid request (%s): %s"
      (invalid_request_reason_to_string r.reason)
      r.message
  | NotFound r -> Printf.sprintf "Not found: %s" r.message
  | ContextOverflow r ->
    let limit_str =
      match r.limit with
      | Some n -> Printf.sprintf " (limit: %d)" n
      | None -> ""
    in
    Printf.sprintf "Context overflow%s: %s" limit_str r.message
  | InputCapacity r ->
    let reason =
      match r.reason with
      | Serving_constraint_rejected reason ->
        Serving_constraint.show_admission_error reason
      | Token_measurement_unavailable protocol ->
        "token_measurement_unavailable(" ^ Input_token_count.show_protocol protocol ^ ")"
    in
    Printf.sprintf "Input capacity (%s): %s" reason r.message
  | NetworkError { message; kind = Unknown } -> Printf.sprintf "Network error: %s" message
  | NetworkError
      { message
      ; kind =
          ( Http_client.Connection_refused
          | Http_client.Dns_failure
          | Http_client.Unreachable
          | Http_client.Tls_error
          | Http_client.Timeout
          | Http_client.Local_resource_exhaustion
          | Http_client.Connection_reset
          | Http_client.End_of_file ) as kind
      } ->
    Printf.sprintf "Network error (%s): %s" (Http_client.network_error_kind_to_string kind) message
  | Connect_failed { message; kind } ->
    Printf.sprintf
      "Connect failed (%s): %s"
      (Http_client.network_error_kind_to_string kind)
      message
  | Timeout r ->
    (* The phase is the whole diagnostic value of a timeout -- a stalled stream
       and a refused admission are different failures. It was carried in the
       record and dropped here, which is why the only way to see it in a log was
       to convert the error into a provider error it was not. *)
    let phase_suffix =
      match r.phase with
      | None -> ""
      | Some phase ->
        Printf.sprintf " phase=%s" (Http_client.timeout_phase_to_label phase)
    in
    Printf.sprintf "Timeout%s: %s" phase_suffix r.message
;;

let is_retryable = function
  | RateLimited _ -> true
  | Overloaded _ | ServerError _ | Timeout _ -> true
  | NetworkError { kind; _ } | Connect_failed { kind; _ } ->
    not (Http_client.network_error_kind_is_non_retryable kind)
  | InvalidRequest { reason = Json_parse_error; _ } ->
    (* Malformed JSON from model output is transient — retry may produce valid JSON. *)
    true
  | InvalidRequest { reason = Refusal_body_not_received; _ } ->
    (* The status is the provider's answer; the reason it carried is unread,
       because the caller's own window closed on the body. Nothing here says
       the request itself is what the provider refused, and the next attempt
       opens a fresh window that may read the answer. A determinate refusal
       -- one whose body arrived -- still ends the attempt. *)
    true
  | InvalidRequest
      { reason =
          ( Attempt_rejected
          | Request_body_refused_by_provider _
          | Unknown_invalid_request
          | Unclassified_status _ )
      ; _
      } -> false
  | AuthError _ | AuthorizationError _ | ContextOverflow _ | InputCapacity _ | NotFound _
    -> false
  | PaymentRequired _ -> false
;;

(** Verdict for a provider turn that produced no content blocks.

    An empty turn is never a normal outcome, and the correct recovery differs by
    attribution. [Empty_overflow] can only progress through the consumer's
    context recovery (compaction): retrying or rotating replays the same
    oversized prompt. A recognized non-overflow stop_reason ([Empty_attributed])
    keeps the existing provider-unavailability handling.

    [Empty_unattributed] is the third case, previously folded into the second:
    the provider ended an empty turn with a stop_reason token agent core does not
    model. Retrying or rotating replays the same prompt, so attributing it to
    transient provider unavailability turns an unmodeled provider contract into
    an invisible retry loop — an overflow signalled with an unmodeled token
    never reaches the consumer's compaction path and no error is raised. This
    arm exists so the condition is surfaced rather than guessed. The match is
    exhaustive (no [_] catch-all) so a new [Types.stop_reason] forces a decision
    here.

    The verdict is derived from the typed stop_reason alone — no provider
    identity is consulted, so every backend that reports an empty completion is
    classified by the same rule. *)
type empty_completion_verdict =
  | Empty_overflow of api_error
  | Empty_attributed
  | Empty_unattributed of { token : string }

let verdict_of_empty_completion ~(stop_reason : Types.stop_reason) ~message =
  match stop_reason with
  | Types.ContextWindowExceeded ->
    Empty_overflow
      (ContextOverflow
         { message =
             "empty completion (stop_reason=model_context_window_exceeded): " ^ message
         ; limit = None
         })
  | Types.EndTurn
  | Types.StopToolUse
  | Types.MaxTokens
  | Types.StopSequence
  | Types.Refusal
  | Types.ContentFilter
  | Types.RepetitionTruncation
  | Types.PauseTurn
  | Types.Compaction
  | Types.UnmatchedToolCalls -> Empty_attributed
  | Types.Unknown token -> Empty_unattributed { token }
;;

let%test "verdict_of_empty_completion: ContextWindowExceeded is Empty_overflow" =
  match
    verdict_of_empty_completion ~stop_reason:Types.ContextWindowExceeded ~message:"X"
  with
  | Empty_overflow (ContextOverflow { limit = None; _ }) -> true
  | Empty_overflow
      ( ContextOverflow { limit = Some _; _ }
      | RateLimited _
      | Overloaded _
      | ServerError _
      | AuthError _
      | AuthorizationError _
      | PaymentRequired _
      | InvalidRequest _
      | NotFound _
      | InputCapacity _
      | NetworkError _
      | Connect_failed _
      | Timeout _ )
  | Empty_attributed
  | Empty_unattributed _ -> false
;;

(* An unmodeled stop_reason token must stay distinguishable from a recognized
   non-overflow one: folding it into [Empty_attributed] sends the caller to
   provider-unavailability handling, which retries the identical prompt. *)
let%test "verdict_of_empty_completion: unmodeled token is Empty_unattributed" =
  match
    verdict_of_empty_completion
      ~stop_reason:(Types.Unknown "provider_specific_overflow")
      ~message:"X"
  with
  | Empty_unattributed { token = "provider_specific_overflow" } -> true
  | Empty_unattributed _ | Empty_overflow _ | Empty_attributed -> false
;;

(* Guard against over-classification: a recognized non-overflow stop_reason must
   not be promoted into the unattributed (fail-loud) arm. *)
let%test "verdict_of_empty_completion: recognized non-overflow is Empty_attributed" =
  List.for_all
    (fun stop_reason ->
       match verdict_of_empty_completion ~stop_reason ~message:"X" with
       | Empty_attributed -> true
       | Empty_overflow _ | Empty_unattributed _ -> false)
    [ Types.EndTurn
    ; Types.StopToolUse
    ; Types.MaxTokens
    ; Types.StopSequence
    ; Types.Refusal
    ; Types.ContentFilter
    ; Types.RepetitionTruncation
    ; Types.PauseTurn
    ; Types.Compaction
    ; Types.UnmatchedToolCalls
    ]
;;

(** Extract a human-readable error message from a provider error body.
    Error prose remains diagnostic data only and is never classified. *)
let extract_error_message (body : string) : string =
  Option.value (Api_common.error_message_of_body body) ~default:body
;;

(** A retry_after delay is usable only when it is finite and non-negative:
    those are the values that can feed a sleep/backoff computation without
    producing a nonsensical or unbounded wait. Yojson parses JSON number
    tokens (and its [NaN]/[Infinity]/[-Infinity] extensions, plus overflowing
    exponents like [1e400]) into non-finite floats, and a hostile body may
    carry a negative value; reject all of them here so the value produced at
    the parse boundary is always safe for downstream. [Float.is_finite] is
    load-bearing on its own: [Float.infinity >= 0.0] is [true], so the
    non-negativity check alone would admit [+inf]. *)
let usable_retry_after (seconds : float) : float option =
  if Float.is_finite seconds && seconds >= 0.0 then Some seconds else None
;;

(** Parse the provider-specific [error.retry_after] JSON body field, if
    present and well-formed. This is provider prose, not transport
    evidence, but it is the more precise of the two retry_after signals
    when a provider bothers to emit it. Non-finite or negative values are
    rejected ([None]) at this boundary (parse, don't validate). *)
let parse_body_retry_after (body : string) : float option =
  try
    let json = Json_util.from_string_bounded_exn body in
    let open Yojson.Safe.Util in
    json |> member "error" |> member "retry_after" |> to_number |> usable_retry_after
  with
  | Yojson.Json_error _ | Yojson.Safe.Util.Type_error _ | Yojson.Safe.Util.Undefined _ ->
    None
;;

let resolve_retry_after ~body ~header : float option =
  match parse_body_retry_after body with
  | Some _ as from_body -> from_body
  | None -> header
;;

type structured_refusal =
  | Structured_context_overflow of
      { message : string
      ; limit : int option
      }
  | Structured_account_quota of
      { message : string
      ; retry_after : float option
      }

(* Machine-readable structured provider error signals parsed from JSON error
   fields (code, type, status, metadata.error_type, details[].reason, and
   nested OpenRouter metadata.raw JSON). [messages] supplies the diagnostic
   text attached after classification. *)
type error_signals =
  { codes : string list
  ; types : string list
  ; statuses : string list
  ; detail_reasons : string list
  ; messages : string list
  ; n_ctx : int option
  }

let empty_signals =
  { codes = []
  ; types = []
  ; statuses = []
  ; detail_reasons = []
  ; messages = []
  ; n_ctx = None
  }
;;

let merge_signals a b =
  { codes = a.codes @ b.codes
  ; types = a.types @ b.types
  ; statuses = a.statuses @ b.statuses
  ; detail_reasons = a.detail_reasons @ b.detail_reasons
  ; messages = a.messages @ b.messages
  ; n_ctx = (match a.n_ctx with Some _ as v -> v | None -> b.n_ctx)
  }
;;

let json_string_opt = function
  | `String s ->
    let trimmed = String.trim s in
    if String.length trimmed > 0 then Some trimmed else None
  | `Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let json_code_string_opt = function
  | `String s ->
    let trimmed = String.trim s in
    if String.length trimmed > 0 then Some trimmed else None
  | `Int n -> Some (string_of_int n)
  | `Intlit s -> Some s
  | `Assoc _ | `List _ | `Float _ | `Bool _ | `Null -> None
;;

let json_positive_int_opt = function
  | `Int n when n > 0 -> Some n
  | `Int _ | `Assoc _ | `List _ | `String _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    None
;;

let json_number_opt = function
  | `Float f -> usable_retry_after f
  | `Int n -> usable_retry_after (float_of_int n)
  | `Intlit s -> Option.bind (float_of_string_opt s) usable_retry_after
  | `Assoc _ | `List _ | `String _ | `Bool _ | `Null -> None
;;

(* Strict protobuf Duration string: "<digits>[.<digits>]s" (e.g. "39s", "39.5s").
   Rejects signs, unit-less numbers ("39"), non-numeric suffixes, and non-finite
   values instead of defaulting to 0.0. *)
let parse_protobuf_duration_seconds (raw : string) : float option =
  let s = String.trim raw in
  let len = String.length s in
  if len < 2 || s.[len - 1] <> 's'
  then None
  else (
    let body_len = len - 1 in
    let is_digit c = c >= '0' && c <= '9' in
    let rec check_digits idx saw_dot digits_before digits_after =
      if idx >= body_len
      then digits_before > 0 && ((not saw_dot) || digits_after > 0)
      else (
        let c = s.[idx] in
        if is_digit c
        then
          if saw_dot
          then check_digits (idx + 1) true digits_before (digits_after + 1)
          else check_digits (idx + 1) false (digits_before + 1) digits_after
        else if c = '.' && not saw_dot
        then check_digits (idx + 1) true digits_before digits_after
        else false)
    in
    if check_digits 0 false 0 0
    then Option.bind (float_of_string_opt (String.sub s 0 body_len)) usable_retry_after
    else None)
;;

let retry_info_delay fields =
  match Option.bind (List.assoc_opt "@type" fields) json_string_opt with
  | Some ("type.googleapis.com/google.rpc.RetryInfo" | "google.rpc.RetryInfo") ->
    Option.bind (List.assoc_opt "retryDelay" fields) (function
      | `String raw -> parse_protobuf_duration_seconds raw
      | _ -> None)
  | Some _ | None -> None
;;

let retry_info_in_details fields =
  match List.assoc_opt "details" fields with
  | Some (`List items) ->
    List.find_map (function `Assoc fields -> retry_info_delay fields | _ -> None) items
  | _ -> None
;;

(* Precedence within an object: numeric retry_after -> numeric retryAfter ->
   google.rpc.RetryInfo retryDelay. *)
let retry_after_in_fields fields =
  match Option.bind (List.assoc_opt "retry_after" fields) json_number_opt with
  | Some _ as v -> v
  | None ->
    (match Option.bind (List.assoc_opt "retryAfter" fields) json_number_opt with
     | Some _ as v -> v
     | None ->
       (match retry_info_delay fields with
        | Some _ as delay -> delay
        | None -> retry_info_in_details fields))
;;

let metadata_raw_of_fields fields =
  match List.assoc_opt "metadata" fields with
  | Some (`Assoc mf) -> Option.bind (List.assoc_opt "raw" mf) json_string_opt
  | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
  | None -> None
;;

let metadata_raw_in_envelope ~err_fields ~outer_fields =
  match Option.bind err_fields metadata_raw_of_fields with
  | Some _ as raw -> raw
  | None -> metadata_raw_of_fields outer_fields
;;

let rec retry_after_of_json_depth ~depth (json : Yojson.Safe.t) : float option =
  if depth > 2
  then None
  else
    match json with
    | `Assoc fields ->
      let err_fields =
        match List.assoc_opt "error" fields with
        | Some (`Assoc ef) -> Some ef
        | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> None
      in
      let direct =
        match Option.bind err_fields retry_after_in_fields with
        | Some _ as v -> v
        | None -> retry_after_in_fields fields
      in
      (match direct with
       | Some _ as v -> v
       | None ->
         (match metadata_raw_in_envelope ~err_fields ~outer_fields:fields with
          | None -> None
          | Some raw ->
            (match Json_util.from_string_bounded raw with
             | Ok raw_json -> retry_after_of_json_depth ~depth:(depth + 1) raw_json
             | Error _ -> None)))
    | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let retry_after_of_json (json : Yojson.Safe.t) : float option =
  retry_after_of_json_depth ~depth:0 json
;;

let json_http_status_opt = function
  | `Int n when n >= 400 && n <= 599 -> Some n
  | `Int _ | `Assoc _ | `List _ | `String _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
    None
;;

let http_status_in_fields fields =
  let first_status keys =
    List.find_map
      (fun key -> Option.bind (List.assoc_opt key fields) json_http_status_opt)
      keys
  in
  first_status [ "http_status"; "httpStatus"; "status_code"; "statusCode"; "status"; "code" ]
;;

let rec http_status_of_json_depth ~depth (json : Yojson.Safe.t) : int option =
  if depth > 2
  then None
  else
    match json with
    | `Assoc fields ->
      let err_fields =
        match List.assoc_opt "error" fields with
        | Some (`Assoc ef) -> Some ef
        | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> None
      in
      let direct =
        match Option.bind err_fields http_status_in_fields with
        | Some _ as v -> v
        | None -> http_status_in_fields fields
      in
      (match direct with
       | Some _ as v -> v
       | None ->
         (match metadata_raw_in_envelope ~err_fields ~outer_fields:fields with
          | None -> None
          | Some raw ->
            (match Json_util.from_string_bounded raw with
             | Ok raw_json -> http_status_of_json_depth ~depth:(depth + 1) raw_json
             | Error _ -> None)))
    | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
;;

let http_status_of_json (json : Yojson.Safe.t) : int option =
  http_status_of_json_depth ~depth:0 json
;;

let signals_of_object_fields fields : error_signals =
  let codes =
    List.filter_map
      (fun key -> Option.bind (List.assoc_opt key fields) json_code_string_opt)
      [ "code"; "error_code" ]
  in
  let top_type = Option.bind (List.assoc_opt "type" fields) json_string_opt in
  let err_type = Option.bind (List.assoc_opt "error_type" fields) json_string_opt in
  (* Muse ACP puts its turn failure class in [error.data.error.kind], one of
     the MSP [TurnErrorKind] values ([muse schema generate-json-schema]),
     e.g. ["contextOverflow"] or ["modelError"]. It is a typed field, read the
     same way as [type]. *)
  let kind_type = Option.bind (List.assoc_opt "kind" fields) json_string_opt in
  let metadata_fields =
    match List.assoc_opt "metadata" fields with
    | Some (`Assoc mf) -> Some mf
    | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
    | None -> None
  in
  let meta_type =
    Option.bind metadata_fields (fun mf ->
      Option.bind (List.assoc_opt "error_type" mf) json_string_opt)
  in
  let types = List.filter_map Fun.id [ top_type; err_type; kind_type; meta_type ] in
  let statuses =
    match Option.bind (List.assoc_opt "status" fields) json_string_opt with
    | Some s -> [ s ]
    | None -> []
  in
  let detail_reasons =
    match List.assoc_opt "details" fields with
    | Some (`List items) ->
      List.filter_map
        (function
          | `Assoc df -> Option.bind (List.assoc_opt "reason" df) json_string_opt
          | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None)
        items
    | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
    | None -> []
  in
  let direct_message = Option.bind (List.assoc_opt "message" fields) json_string_opt in
  let flat_error_message =
    match List.assoc_opt "error" fields with
    | Some (`String _ as s) -> json_string_opt s
    | Some (`Assoc _ | `List _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
    | None -> None
  in
  let messages = List.filter_map Fun.id [ direct_message; flat_error_message ] in
  let n_ctx = Option.bind (List.assoc_opt "n_ctx" fields) json_positive_int_opt in
  { codes; types; statuses; detail_reasons; messages; n_ctx }
;;

let rec extract_signals_from_json ~depth (json : Yojson.Safe.t) : error_signals =
  if depth > 2
  then empty_signals
  else
    match json with
    | `Assoc fields ->
      let err_fields =
        match List.assoc_opt "error" fields with
        | Some (`Assoc ef) -> Some ef
        | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> None
      in
      let outer = signals_of_object_fields fields in
      let base =
        match err_fields with
        | Some ef -> merge_signals (signals_of_object_fields ef) outer
        | None -> outer
      in
      (* OpenRouter embeds the upstream provider's structured JSON error object
         as a string inside [error.metadata.raw]. Parse it as JSON with the same
         structured extractor so upstream error codes/types survive proxying. *)
      let nested =
        match metadata_raw_in_envelope ~err_fields ~outer_fields:fields with
        | None -> empty_signals
        | Some raw ->
          (match Json_util.from_string_bounded raw with
           | Ok raw_json -> extract_signals_from_json ~depth:(depth + 1) raw_json
           | Error _ -> empty_signals)
      in
      merge_signals base nested
    | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
      empty_signals
;;

let signals_of_json (json : Yojson.Safe.t) : error_signals =
  extract_signals_from_json ~depth:0 json
;;

let signals_of_body (body : string) : error_signals =
  match Json_util.from_string_bounded body with
  | Ok json -> signals_of_json json
  | Error _ -> empty_signals
;;

(* Preserve the exact pre-stack [main] HTTP JSON signal extractor and refusal
   code/type tables exclusively for {!classify_structured_refusal} /
   {!classify_error} so existing HTTP backend behavior stays 100% invariant
   while non-HTTP / ACP structured signal helpers use the wider normalized
   tables below. *)
let rec extract_http_signals_from_json ~depth (json : Yojson.Safe.t) : error_signals =
  if depth > 2
  then empty_signals
  else
    match json with
    | `Assoc fields ->
      let err_obj =
        match List.assoc_opt "error" fields with
        | Some (`Assoc err_fields) -> err_fields
        | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> fields
      in
      let codes =
        match Option.bind (List.assoc_opt "code" err_obj) json_code_string_opt with
        | Some c -> [ c ]
        | None -> []
      in
      let top_type = Option.bind (List.assoc_opt "type" err_obj) json_string_opt in
      let metadata_fields =
        match List.assoc_opt "metadata" err_obj with
        | Some (`Assoc mf) -> Some mf
        | Some (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> None
      in
      let meta_type =
        Option.bind metadata_fields (fun mf ->
          Option.bind (List.assoc_opt "error_type" mf) json_string_opt)
      in
      let types = List.filter_map Fun.id [ top_type; meta_type ] in
      let statuses =
        match Option.bind (List.assoc_opt "status" err_obj) json_string_opt with
        | Some s -> [ s ]
        | None -> []
      in
      let detail_reasons =
        match List.assoc_opt "details" err_obj with
        | Some (`List items) ->
          List.filter_map
            (function
              | `Assoc df -> Option.bind (List.assoc_opt "reason" df) json_string_opt
              | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
                None)
            items
        | Some (`Assoc _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null)
        | None -> []
      in
      let messages =
        match Option.bind (List.assoc_opt "message" err_obj) json_string_opt with
        | Some m -> [ m ]
        | None -> []
      in
      let n_ctx = Option.bind (List.assoc_opt "n_ctx" err_obj) json_positive_int_opt in
      let base = { codes; types; statuses; detail_reasons; messages; n_ctx } in
      let nested =
        match
          Option.bind metadata_fields (fun mf ->
            Option.bind (List.assoc_opt "raw" mf) json_string_opt)
        with
        | None -> empty_signals
        | Some raw ->
          (match Json_util.from_string_bounded raw with
           | Ok raw_json -> extract_http_signals_from_json ~depth:(depth + 1) raw_json
           | Error _ -> empty_signals)
      in
      merge_signals base nested
    | `List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null ->
      empty_signals
;;

let http_signals_of_body (body : string) : error_signals =
  match Json_util.from_string_bounded body with
  | Ok json -> extract_http_signals_from_json ~depth:0 json
  | Error _ -> empty_signals
;;

(* The GLM codec interprets Z.AI numeric codes through
   [Complete_common.provider_refusal] before the common HTTP classifier runs. *)
let is_http_context_overflow_code code =
  match code with
  | "context_length_exceeded"
  | "string_above_max_length"
  | "model_context_window_exceeded"
  | "3200" -> true
  | _ -> false
;;

let is_http_context_overflow_type = function
  | "context_length_exceeded" | "exceed_context_size_error" | "request_too_large" -> true
  | _ -> false
;;

let is_http_context_overflow_reason = function
  | "CONTEXT_LENGTH_EXCEEDED" | "PROMPT_TOO_LONG" -> true
  | _ -> false
;;

let is_http_quota_code code =
  match code with
  | "insufficient_quota"
  | "billing_hard_limit_reached"
  | "credit_balance_too_low"
  | "key_limit_exceeded"
  | "quota_exceeded"
  | "usage_limit_exceeded"
  (* Mistral API: billing_api_budget_exhausted (code 2303). *)
  | "2303" -> true
  | _ -> false
;;

let is_http_quota_type = function
  | "insufficient_quota"
  | "billing_error"
  | "quota_exceeded"
  | "key_limit_exceeded"
  | "usage_limit_exceeded"
  | "GoUsageLimitError" -> true
  | _ -> false
;;

let is_http_quota_reason = function
  | "QUOTA_EXCEEDED" | "BILLING_DISABLED" -> true
  | _ -> false
;;

let http_signals_indicate_context_overflow (s : error_signals) =
  List.exists is_http_context_overflow_code s.codes
  || List.exists is_http_context_overflow_type s.types
  || List.exists is_http_context_overflow_reason s.detail_reasons
;;

let http_signals_indicate_account_quota (s : error_signals) =
  List.exists is_http_quota_code s.codes
  || List.exists is_http_quota_type s.types
  || List.exists is_http_quota_reason s.detail_reasons
;;

let is_structured_context_overflow_code code =
  let normalized = String.lowercase_ascii (String.trim code) in
  match normalized with
  | "context_length_exceeded"
  | "context_window_exceeded"
  | "string_above_max_length"
  | "model_context_window_exceeded"
  | "model_context_length_exceeded"
  | "prompt_too_long"
  | "max_tokens_exceeded"
  | "request_too_large"
  | "invalid_argument_prompt_too_long"
  | "3200" -> true
  | _ -> false
;;

let is_structured_context_overflow_type t =
  match String.lowercase_ascii (String.trim t) with
  | "contextoverflow" (* Muse MSP TurnErrorKind [contextOverflow] *)
  | "context_length_exceeded"
  | "context_window_exceeded"
  | "exceed_context_size_error"
  | "request_too_large"
  | "max_tokens_exceeded"
  | "prompt_too_long" -> true
  | _ -> false
;;

let is_structured_context_overflow_reason reason =
  match String.uppercase_ascii (String.trim reason) with
  | "CONTEXT_LENGTH_EXCEEDED"
  | "CONTEXT_WINDOW_EXCEEDED"
  | "PROMPT_TOO_LONG"
  | "MAX_TOKENS_EXCEEDED" -> true
  | _ -> false
;;

let is_structured_quota_code code =
  let normalized = String.lowercase_ascii (String.trim code) in
  match normalized with
  | "exceeded_current_quota_error"
  | "insufficient_quota"
  | "billing_hard_limit_reached"
  | "billing_api_budget_exhausted"
  | "billing_disabled"
  | "credit_balance_too_low"
  | "insufficient_balance"
  | "payment_required"
  | "key_limit_exceeded"
  | "quota_exceeded"
  | "usage_limit_exceeded"
  (* Mistral API: billing_api_budget_exhausted (code 2303). *)
  | "2303" -> true
  | _ -> false
;;

let is_structured_quota_type t =
  match String.lowercase_ascii (String.trim t) with
  | "exceeded_current_quota_error"
  | "insufficient_quota"
  | "billing_error"
  | "billing_hard_limit_reached"
  | "billing_api_budget_exhausted"
  | "insufficient_balance"
  | "insufficient_balance_error"
  | "payment_required"
  | "quota_exceeded"
  | "key_limit_exceeded"
  | "usage_limit_exceeded"
  | "gousagelimiterror" -> true
  | _ -> false
;;

let is_structured_quota_reason reason =
  match String.uppercase_ascii (String.trim reason) with
  | "QUOTA_EXCEEDED" | "BILLING_DISABLED" -> true
  | _ -> false
;;

let is_structured_rate_limit_token value =
  match String.lowercase_ascii (String.trim value) with
  | "resource_exhausted"
  | "rate_limit_exceeded"
  | "rate_limit_error"
  | "too_many_requests" -> true
  | _ -> false
;;

let is_structured_auth_token value =
  match String.lowercase_ascii (String.trim value) with
  | "unauthenticated"
  | "authentication_error"
  | "invalid_authentication_error"
  | "invalid_api_key"
  | "unauthorized" -> true
  | _ -> false
;;

let is_structured_authorization_token value =
  match String.lowercase_ascii (String.trim value) with
  | "permission_denied"
  | "permission_error"
  | "forbidden"
  | "access_denied" -> true
  | _ -> false
;;

let is_structured_unavailable_token value =
  match String.lowercase_ascii (String.trim value) with
  | "overloaded_error"
  | "api_error"
  | "server_error"
  | "service_unavailable"
  | "internal_error"
  | "internal_server_error"
  | "bad_gateway"
  | "gateway_timeout"
  | "unavailable"
  | "deadline_exceeded" -> true
  | _ -> false
;;

let signals_indicate_context_overflow (s : error_signals) =
  List.exists is_structured_context_overflow_code s.codes
  || List.exists is_structured_context_overflow_type s.types
  || List.exists is_structured_context_overflow_code s.statuses
  || List.exists is_structured_context_overflow_reason s.statuses
  || List.exists is_structured_context_overflow_reason s.detail_reasons
;;

let signals_indicate_account_quota (s : error_signals) =
  List.exists is_structured_quota_code s.codes
  || List.exists is_structured_quota_type s.types
  || List.exists is_structured_quota_code s.statuses
  || List.exists is_structured_quota_reason s.statuses
  || List.exists is_structured_quota_reason s.detail_reasons
;;

let signals_indicate_rate_limit (s : error_signals) =
  List.exists is_structured_rate_limit_token s.codes
  || List.exists is_structured_rate_limit_token s.types
  || List.exists is_structured_rate_limit_token s.statuses
  || List.exists is_structured_rate_limit_token s.detail_reasons
;;

let signals_indicate_auth_error (s : error_signals) =
  List.exists is_structured_auth_token s.codes
  || List.exists is_structured_auth_token s.types
  || List.exists is_structured_auth_token s.statuses
  || List.exists is_structured_auth_token s.detail_reasons
;;

let signals_indicate_authorization_error (s : error_signals) =
  List.exists is_structured_authorization_token s.codes
  || List.exists is_structured_authorization_token s.types
  || List.exists is_structured_authorization_token s.statuses
  || List.exists is_structured_authorization_token s.detail_reasons
;;

let signals_indicate_provider_unavailable (s : error_signals) =
  List.exists is_structured_unavailable_token s.codes
  || List.exists is_structured_unavailable_token s.types
  || List.exists is_structured_unavailable_token s.statuses
  || List.exists is_structured_unavailable_token s.detail_reasons
;;

let structured_refusal_of_signals_with
      ~indicates_overflow
      ~indicates_quota
      ~retry_after
      ~status
      ~message
      (signals : error_signals)
  : structured_refusal option
  =
  match status with
  | 400 | 422 ->
    if indicates_overflow signals
    then Some (Structured_context_overflow { message; limit = signals.n_ctx })
    else if indicates_quota signals
    then Some (Structured_account_quota { message; retry_after })
    else None
  | 402 -> Some (Structured_account_quota { message; retry_after })
  | 403 ->
    (* Require an explicit structured quota/billing signal on 403; a WAF/CDN
       403 carrying only Retry-After stays AuthorizationError until a provider
       usage-window read confirms the account budget is spent. *)
    if indicates_quota signals
    then Some (Structured_account_quota { message; retry_after })
    else None
  | 429 ->
    if indicates_quota signals
    then Some (Structured_account_quota { message; retry_after })
    else None
  | _ -> None
;;

let structured_refusal_of_signals ~retry_after ~status ~message (signals : error_signals)
  : structured_refusal option
  =
  structured_refusal_of_signals_with
    ~indicates_overflow:signals_indicate_context_overflow
    ~indicates_quota:signals_indicate_account_quota
    ~retry_after
    ~status
    ~message
    signals
;;

let message_of_signals ?(fallback_message = "") (signals : error_signals) =
  match signals.messages with
  | m :: _ -> m
  | [] -> fallback_message
;;

let structured_refusal_of_json ?retry_after ~status (json : Yojson.Safe.t)
  : structured_refusal option
  =
  let signals = signals_of_json json in
  let effective_retry =
    match retry_after_of_json json with
    | Some _ as from_json -> from_json
    | None -> Option.bind retry_after usable_retry_after
  in
  let message = message_of_signals signals in
  structured_refusal_of_signals ~retry_after:effective_retry ~status ~message signals
;;

let classify_structured_refusal ~retry_after_header ~status ~body : structured_refusal option =
  let message = extract_error_message body in
  let signals = http_signals_of_body body in
  let retry_after = resolve_retry_after ~body ~header:retry_after_header in
  structured_refusal_of_signals_with
    ~indicates_overflow:http_signals_indicate_context_overflow
    ~indicates_quota:http_signals_indicate_account_quota
    ~retry_after
    ~status
    ~message
    signals
;;

type signal_refusal =
  | Signal_context_overflow of
      { message : string
      ; limit : int option
      }
  | Signal_request_body_too_large of { message : string }
  | Signal_hard_quota of
      { message : string
      ; retry_after : float option
      }
  | Signal_rate_limited of
      { message : string
      ; retry_after : float option
      }
  | Signal_auth_error of { message : string }
  | Signal_authorization_error of { message : string }
  | Signal_provider_unavailable of { message : string }

let refusal_http_status_opt = function
  | Some s when s >= 400 && s <= 599 -> Some s
  | Some _ | None -> None
;;

let classify_structured_signals
      ?http_status
      ?retry_after
      ?(fallback_message = "")
      (signals : error_signals)
  : signal_refusal option
  =
  let retry_after = Option.bind retry_after usable_retry_after in
  let message = message_of_signals ~fallback_message signals in
  let classify_non_quota_overflow_fields () =
    if signals_indicate_rate_limit signals
    then Some (Signal_rate_limited { message; retry_after })
    else if signals_indicate_auth_error signals
    then Some (Signal_auth_error { message })
    else if signals_indicate_authorization_error signals
    then Some (Signal_authorization_error { message })
    else if signals_indicate_provider_unavailable signals
    then Some (Signal_provider_unavailable { message })
    else None
  in
  let classify_by_fields () =
    if signals_indicate_account_quota signals
    then Some (Signal_hard_quota { message; retry_after })
    else if signals_indicate_context_overflow signals
    then Some (Signal_context_overflow { message; limit = signals.n_ctx })
    else classify_non_quota_overflow_fields ()
  in
  match refusal_http_status_opt http_status with
  | Some 402 -> Some (Signal_hard_quota { message; retry_after })
  | Some 401 -> Some (Signal_auth_error { message })
  | Some 403 ->
    if signals_indicate_account_quota signals
    then Some (Signal_hard_quota { message; retry_after })
    else Some (Signal_authorization_error { message })
  | Some 429 ->
    if signals_indicate_account_quota signals
    then Some (Signal_hard_quota { message; retry_after })
    else Some (Signal_rate_limited { message; retry_after })
  | Some 413 -> Some (Signal_request_body_too_large { message })
  | Some (400 | 422 as status) ->
    (match structured_refusal_of_signals ~retry_after ~status ~message signals with
     | Some (Structured_context_overflow { message; limit }) ->
       Some (Signal_context_overflow { message; limit })
     | Some (Structured_account_quota { message; retry_after }) ->
       Some (Signal_hard_quota { message; retry_after })
     | None -> classify_non_quota_overflow_fields ())
  | Some status ->
    (match server_status_class_of_code status with
     | Some (Overloaded_status | Server_error_status) ->
       Some (Signal_provider_unavailable { message })
     | None -> classify_by_fields ())
  | None -> classify_by_fields ()
;;

let classify_structured_json
      ?http_status
      ?retry_after
      ?fallback_message
      (json : Yojson.Safe.t)
  : signal_refusal option
  =
  (* An ACP data array can split the status, provider refusal, and retry
     evidence into separate objects. Classify the covered fields together. *)
  let objects = match json with
    | `List items -> List.take 8 items
    | other -> [ other ]
  in
  let signals =
    List.fold_left (fun acc obj -> merge_signals acc (signals_of_json obj)) empty_signals objects
  in
  let effective_status =
    match refusal_http_status_opt http_status with
    | Some _ as status -> status
    | None -> List.find_map http_status_of_json objects
  in
  let effective_retry =
    match List.find_map retry_after_of_json objects with
    | Some _ as retry -> retry
    | None -> Option.bind retry_after usable_retry_after
  in
  classify_structured_signals
    ?http_status:effective_status
    ?retry_after:effective_retry
    ?fallback_message
    signals
;;

(* Scan up to [max_attempts] '{'-anchored balanced JSON object spans inside
   [text], respecting JSON string quoting and backslash escapes. Bounded to
   64 KiB and 8 attempts on both fast and scan paths so adversarial payloads or
   unbalanced prefixes (such as ["{prefix {\"error\":...}}"]) cannot stall
   classification or mask a valid embedded JSON envelope later in the string.
   Top-level JSON arrays (such as Gemini streaming [[{"error":{...}}]]) inspect
   up to 8 leading object entries. *)
let classify_embedded_json ?http_status ?retry_after (text : string) : signal_refusal option =
  let trimmed = String.trim text in
  if trimmed = ""
  then None
  else (
    let max_bytes = 65536 in
    let bounded =
      if String.length trimmed <= max_bytes then trimmed else String.sub trimmed 0 max_bytes
    in
    let classify_json = function
      | `Assoc _ as obj ->
        classify_structured_json ?http_status ?retry_after ~fallback_message:bounded obj
      | `List items ->
        let rec walk_items remaining items =
          if remaining <= 0
          then None
          else (
            match items with
            | [] -> None
            | (`Assoc _ as item) :: rest ->
              (match
                 classify_structured_json
                   ?http_status
                   ?retry_after
                   ~fallback_message:bounded
                   item
               with
               | Some _ as matched -> matched
               | None -> walk_items (remaining - 1) rest)
            | (`List _ | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null) :: rest ->
              walk_items (remaining - 1) rest)
        in
        walk_items 8 items
      | `String _ | `Int _ | `Intlit _ | `Float _ | `Bool _ | `Null -> None
    in
    let try_slice slice =
      match Json_util.from_string_bounded slice with
      | Ok json -> Ok (classify_json json)
      | Error _ -> Error ()
    in
    let fast_path =
      if String.length trimmed <= max_bytes then try_slice trimmed else Error ()
    in
    match fast_path with
    | Ok (Some _ as matched) -> matched
    | Ok None -> None
    | Error () ->
      let len = String.length bounded in
      let find_end start =
        let rec loop idx depth in_str escaped =
          if idx >= len
          then None
          else (
            let c = bounded.[idx] in
            if in_str
            then
              if escaped
              then loop (idx + 1) depth true false
              else if c = '\\'
              then loop (idx + 1) depth true true
              else if c = '"'
              then loop (idx + 1) depth false false
              else loop (idx + 1) depth true false
            else if c = '"'
            then loop (idx + 1) depth true false
            else if c = '{'
            then loop (idx + 1) (depth + 1) false false
            else if c = '}'
            then
              if depth <= 1 then Some (idx + 1) else loop (idx + 1) (depth - 1) false false
            else loop (idx + 1) depth false false)
        in
        loop (start + 1) 1 false false
      in
      let rec scan idx attempts =
        if idx >= len || attempts <= 0
        then None
        else if bounded.[idx] = '{'
        then (
          match find_end idx with
          | Some stop ->
            let slice = String.sub bounded idx (stop - idx) in
            (match try_slice slice with
             | Ok (Some _ as matched) -> matched
             | Ok None -> scan stop (attempts - 1)
             | Error () -> scan (idx + 1) (attempts - 1))
          | None -> scan (idx + 1) (attempts - 1))
        else scan (idx + 1) attempts
      in
      scan 0 8)
;;

let is_ascii_ident_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let extract_ascii_tokens (text : string) : (int * int * string) list =
  let total_len = String.length text in
  let len = min total_len 16384 in
  let rec skip_sep idx acc =
    if idx >= len
    then List.rev acc
    else if is_ascii_ident_char text.[idx]
    then scan_tok idx (idx + 1) acc
    else skip_sep (idx + 1) acc
  and scan_tok start idx acc =
    if idx < len && is_ascii_ident_char text.[idx]
    then scan_tok start (idx + 1) acc
    else if idx = len && total_len > len && is_ascii_ident_char text.[len]
    then List.rev acc
    else (
      let tok = String.sub text start (idx - start) in
      skip_sep idx ((start, idx, tok) :: acc))
  in
  skip_sep 0 []
;;

let is_http_version_and_space text ~from ~until =
  let is_digit c = c >= '0' && c <= '9' in
  let is_hspace c = c = ' ' || c = '\t' in
  let rec skip_hspace idx =
    if idx >= until
    then idx
    else if is_hspace text.[idx]
    then skip_hspace (idx + 1)
    else idx
  in
  let rec skip_digits idx =
    if idx < until && is_digit text.[idx] then skip_digits (idx + 1) else idx
  in
  if from >= until
  then false
  else if text.[from] = '/'
  then (
    let after_major = skip_digits (from + 1) in
    if after_major = from + 1
    then false
    else (
      let after_ver =
        if after_major < until && text.[after_major] = '.'
        then (
          let after_minor = skip_digits (after_major + 1) in
          if after_minor = after_major + 1 then -1 else after_minor)
        else after_major
      in
      after_ver > 0
      && after_ver < until
      && is_hspace text.[after_ver]
      && skip_hspace after_ver = until))
  else is_hspace text.[from] && skip_hspace from = until
;;

let explicit_http_refusal_status_in_tokens text tokens =
  let parse_refusal_code tok =
    if String.length tok = 3
    then (
      match int_of_string_opt tok with
      | Some (401 | 402 | 403 | 413 | 429 as s) -> Some s
      | Some s when Option.is_some (server_status_class_of_code s) -> Some s
      | Some _ | None -> None)
    else None
  in
  let has_valid_code_trailing_boundary end_pos =
    if end_pos >= String.length text
    then true
    else (
      match text.[end_pos] with
      | '-' | '/' | '.' -> false
      | _ -> true)
  in
  let rec walk = function
    | (_s1, e1, t1) :: rest
      when String.equal (String.lowercase_ascii t1) "http" ->
      let rec find_code = function
        | (s2, e2, t2) :: tl ->
          if is_http_version_and_space text ~from:e1 ~until:s2
          then (
            if has_valid_code_trailing_boundary e2
            then (
              match parse_refusal_code t2 with
              | Some _ as status -> status
              | None -> walk rest)
            else walk rest)
          else if s2 - e1 <= 12
          then find_code tl
          else walk rest
        | [] -> walk rest
      in
      find_code rest
    | _ :: rest -> walk rest
    | [] -> None
  in
  walk tokens
;;

(* Exact unambiguous machine wire-code tokens accepted when a non-HTTP CLI or
   JSON-RPC server wraps an upstream refusal code into a plain message string
   without a structured JSON envelope. Every token here is an explicit wire
   identifier (snake_case, ALL-CAPS gRPC status, or CamelCase error type) —
   ordinary English words (forbidden, unauthorized, overloaded, throttled,
   token limit, permission denied, etc.) are intentionally excluded. *)
let is_exact_machine_wire_token = function
  (* Hard quota / billing *)
  | "exceeded_current_quota_error"
  | "insufficient_quota"
  | "quota_exceeded"
  | "QUOTA_EXCEEDED"
  | "usage_limit_exceeded"
  | "billing_error"
  | "billing_hard_limit_reached"
  | "billing_api_budget_exhausted"
  | "billing_disabled"
  | "BILLING_DISABLED"
  | "credit_balance_too_low"
  | "insufficient_balance"
  | "insufficient_balance_error"
  | "payment_required"
  | "PAYMENT_REQUIRED"
  | "key_limit_exceeded"
  | "GoUsageLimitError"
  (* Rate limit *)
  | "RESOURCE_EXHAUSTED"
  | "resource_exhausted"
  | "rate_limit_exceeded"
  | "rate_limit_error"
  | "too_many_requests"
  | "TOO_MANY_REQUESTS"
  (* Auth *)
  | "UNAUTHENTICATED"
  | "invalid_api_key"
  | "authentication_error"
  | "invalid_authentication_error"
  (* Authorization *)
  | "PERMISSION_DENIED"
  | "permission_error"
  | "access_denied"
  (* Context overflow *)
  | "contextOverflow"
  | "CONTEXT_OVERFLOW"
  | "context_length_exceeded"
  | "CONTEXT_LENGTH_EXCEEDED"
  | "context_window_exceeded"
  | "CONTEXT_WINDOW_EXCEEDED"
  | "model_context_window_exceeded"
  | "model_context_length_exceeded"
  | "max_tokens_exceeded"
  | "MAX_TOKENS_EXCEEDED"
  | "prompt_too_long"
  | "PROMPT_TOO_LONG"
  | "request_too_large"
  | "REQUEST_TOO_LARGE"
  | "exceed_context_size_error"
  | "string_above_max_length"
  | "invalid_argument_prompt_too_long"
  (* Provider unavailable *)
  | "api_error"
  | "internal_error"
  | "overloaded_error"
  | "service_unavailable"
  | "SERVICE_UNAVAILABLE"
  | "DEADLINE_EXCEEDED"
  | "internal_server_error"
  | "bad_gateway"
  | "gateway_timeout"
  | "server_error" -> true
  | _ -> false
;;

let is_non_overflow_http_refusal_status = function
  | 401 | 402 | 403 | 413 | 429 -> true
  | status -> Option.is_some (server_status_class_of_code status)
;;

let http_status_of_machine_tokens (text : string) : int option =
  let trimmed = String.trim text in
  if trimmed = ""
  then None
  else explicit_http_refusal_status_in_tokens trimmed (extract_ascii_tokens trimmed)
;;

(* Exact key=value wire reason matcher for Google/Antigravity CLI responses
   such as ["... reason=QUOTA_EXHAUSTED"]. Requires contiguous [=] with exact
   key ["reason"] and ALL-CAPS ["QUOTA_EXHAUSTED"] token boundaries. *)
let has_exact_reason_quota_exhausted text tokens =
  let rec walk = function
    | (_s1, e1, t1) :: ((s2, _e2, t2) :: _ as rest) ->
      if String.equal (String.lowercase_ascii t1) "reason"
         && s2 = e1 + 1
         && e1 < String.length text
         && text.[e1] = '='
         && String.equal t2 "QUOTA_EXHAUSTED"
      then true
      else walk rest
    | [ _ ] | [] -> false
  in
  walk tokens
;;

let signals_of_machine_tokens trimmed tokens =
  let matched_codes =
    List.filter_map
      (fun (_, _, tok) -> if is_exact_machine_wire_token tok then Some tok else None)
      tokens
  in
  let detail_reasons =
    if has_exact_reason_quota_exhausted trimmed tokens
    then "QUOTA_EXCEEDED" :: matched_codes
    else matched_codes
  in
  { codes = matched_codes
  ; types = matched_codes
  ; statuses = matched_codes
  ; detail_reasons
  ; messages = (if trimmed = "" then [] else [ trimmed ])
  ; n_ctx = None
  }
;;

let classify_machine_tokens ?http_status ?retry_after (text : string) : signal_refusal option =
  let trimmed = String.trim text in
  let tokens = extract_ascii_tokens trimmed in
  let effective_status =
    match refusal_http_status_opt http_status with
    | Some _ as s -> s
    | None -> explicit_http_refusal_status_in_tokens trimmed tokens
  in
  let signals = signals_of_machine_tokens trimmed tokens in
  classify_structured_signals
    ?http_status:effective_status
    ?retry_after
    ~fallback_message:trimmed
    signals
;;

let signal_retry_after_opt = function
  | Signal_hard_quota { retry_after; _ } | Signal_rate_limited { retry_after; _ } ->
    retry_after
  | Signal_context_overflow _
  | Signal_request_body_too_large _
  | Signal_auth_error _
  | Signal_authorization_error _
  | Signal_provider_unavailable _ -> None
;;

let signal_message_of = function
  | Signal_context_overflow { message; _ }
  | Signal_request_body_too_large { message }
  | Signal_hard_quota { message; _ }
  | Signal_rate_limited { message; _ }
  | Signal_auth_error { message }
  | Signal_authorization_error { message }
  | Signal_provider_unavailable { message } -> message
;;

let signal_is_hard_quota = function
  | Some (Signal_hard_quota _) -> true
  | Some
      ( Signal_context_overflow _
      | Signal_request_body_too_large _
      | Signal_rate_limited _
      | Signal_auth_error _
      | Signal_authorization_error _
      | Signal_provider_unavailable _ )
  | None -> false
;;

let first_some_opt items = List.find_map Fun.id items

let classify_text ?http_status ?retry_after (text : string) : signal_refusal option =
  let trimmed = String.trim text in
  if trimmed = ""
  then None
  else (
    let tokens = extract_ascii_tokens trimmed in
    let caller_status = refusal_http_status_opt http_status in
    let token_status = explicit_http_refusal_status_in_tokens trimmed tokens in
    let effective_status = first_some_opt [ caller_status; token_status ] in
    let caller_retry = Option.bind retry_after usable_retry_after in
    (* Extract pure embedded JSON and pure machine-token signals without forcing
       caller/token HTTP status yet so an unrelated leading JSON object (e.g.
       {"requestId":"x"}) cannot prematurely short-circuit a later quota signal. *)
    let json_signal = classify_embedded_json ?retry_after:caller_retry trimmed in
    let token_signals = signals_of_machine_tokens trimmed tokens in
    let token_signal =
      classify_structured_signals
        ?retry_after:caller_retry
        ~fallback_message:trimmed
        token_signals
    in
    let best_retry =
      first_some_opt
        [ Option.bind json_signal signal_retry_after_opt
        ; caller_retry
        ; Option.bind token_signal signal_retry_after_opt
        ]
    in
    let best_message =
      match json_signal with
      | Some s ->
        let m = signal_message_of s in
        if String.trim m <> "" then m else trimmed
      | None -> trimmed
    in
    let has_hard_quota =
      signal_is_hard_quota json_signal || signal_is_hard_quota token_signal
    in
    let merge_statusless () =
      match json_signal with
      | Some (Signal_hard_quota { message; _ }) ->
        Some (Signal_hard_quota { message; retry_after = best_retry })
      | Some
          ( Signal_context_overflow _
          | Signal_request_body_too_large _
          | Signal_rate_limited _
          | Signal_auth_error _
          | Signal_authorization_error _
          | Signal_provider_unavailable _ ) ->
        if signal_is_hard_quota token_signal
        then Some (Signal_hard_quota { message = best_message; retry_after = best_retry })
        else json_signal
      | None ->
        (match token_signal with
         | Some (Signal_hard_quota { message; _ }) ->
           Some (Signal_hard_quota { message; retry_after = best_retry })
         | Some (Signal_rate_limited { message; _ }) ->
           Some (Signal_rate_limited { message; retry_after = best_retry })
         | Some
             ( Signal_context_overflow _
             | Signal_request_body_too_large _
             | Signal_auth_error _
             | Signal_authorization_error _
             | Signal_provider_unavailable _ ) as s -> s
         | None -> None)
    in
    match effective_status with
    | Some 402 ->
      Some (Signal_hard_quota { message = best_message; retry_after = best_retry })
    | Some 401 -> Some (Signal_auth_error { message = best_message })
    | Some 403 ->
      if has_hard_quota
      then Some (Signal_hard_quota { message = best_message; retry_after = best_retry })
      else Some (Signal_authorization_error { message = best_message })
    | Some 429 ->
      if has_hard_quota
      then Some (Signal_hard_quota { message = best_message; retry_after = best_retry })
      else Some (Signal_rate_limited { message = best_message; retry_after = best_retry })
    | Some 413 -> Some (Signal_request_body_too_large { message = best_message })
    | Some (400 | 422 as status) ->
      (match classify_embedded_json ~http_status:status ?retry_after:best_retry trimmed with
       | Some _ as s -> s
       | None ->
         classify_structured_signals
           ~http_status:status
           ?retry_after:best_retry
           ~fallback_message:trimmed
           token_signals)
    | Some status ->
      (match server_status_class_of_code status with
       | Some (Overloaded_status | Server_error_status) ->
         Some (Signal_provider_unavailable { message = best_message })
       | None -> merge_statusless ())
    | None -> merge_statusless ())
;;

(** Classify HTTP status + body into structured api_error *)
let classify_error ~retry_after_header ~status ~body : api_error =
  let message = extract_error_message body in
  match status with
  | 401 -> AuthError { message }
  | 402 -> PaymentRequired { message }
  | 403 ->
    (match classify_structured_refusal ~retry_after_header ~status ~body with
     | Some (Structured_account_quota { message; _ }) -> PaymentRequired { message }
     | Some (Structured_context_overflow { message; limit }) ->
       ContextOverflow { message; limit }
     | None -> AuthorizationError { message })
  | 400 | 422 ->
    (match classify_structured_refusal ~retry_after_header ~status ~body with
     | Some (Structured_context_overflow { message; limit }) ->
       ContextOverflow { message; limit }
     | Some (Structured_account_quota { message; _ }) -> PaymentRequired { message }
     | None -> InvalidRequest { message; reason = Unknown_invalid_request })
  | 413 ->
    (* HTTP 413 states the refusal cause in the status line: the payload was too
       large. Leaving it in the catch-all below would report a status without
       that cause, which a consumer cannot read as a size it can reduce. The response carries a status,
       not a bound, and none is fabricated. This repository already reads 413 as its own case when attributing
       a failure (provider_failure_attribution.ml, 400 | 413 | 422 -> Attempt_local);
       classification was the asymmetric half. *)
    InvalidRequest { message; reason = Request_body_refused_by_provider { status } }
  | 429 ->
    let retry_after = resolve_retry_after ~body ~header:retry_after_header in
    RateLimited { retry_after; message }
  | 404 -> NotFound { message }
  | status ->
    (match server_status_class_of_code status with
     | Some Overloaded_status -> Overloaded { message }
     | Some Server_error_status -> ServerError { status; message }
     | None ->
       (* A status no arm above names (3xx, 405, 408, 409, ...) is not a 400
          or 422 refusal of the request, and filing it as one let a consumer
          read it as a defect in what it sent. It keeps its own reason and the
          status it came with. *)
       InvalidRequest { message; reason = Unclassified_status { status } })
;;

(* The refusal a transport reports, classified. A body that arrived is
   classified from what it says; a body the caller's own window closed on
   before it arrived is classified from the status alone, as a refusal whose
   cause is unread -- reading an absent body as an empty one would file it
   as a cause the provider named. *)
let classify_refusal ~retry_after_header ~status ~(body : Http_client.refusal_body) : api_error =
  match body with
  | Http_client.Received body -> classify_error ~retry_after_header ~status ~body
  | Http_client.Not_received_in_window ->
    InvalidRequest
      { message =
          Printf.sprintf
            "HTTP %d; the refusal body did not arrive before the caller's window closed"
            status
      ; reason = Refusal_body_not_received
      }
;;

[@@@coverage off]

let%test "extract_error_message: nested error.message (Openai shape)" =
  extract_error_message {|{"error":{"message":"invalid tool schema","code":400}}|}
  = "invalid tool schema"
;;

let%test "extract_error_message: flat error string (Ollama/llama.cpp shape)" =
  extract_error_message
    {|{"error":"Value looks like object, but can't find closing '}' symbol"}|}
  = "Value looks like object, but can't find closing '}' symbol"
;;

let%test "extract_error_message: ZAI Glm quota shape with string code" =
  extract_error_message
    {|{"error":{"code":"1113","message":"Insufficient balance or no resource package. Please recharge."}}|}
  = "Insufficient balance or no resource package. Please recharge."
;;

let%test "extract_error_message: a blank message falls back to the body" =
  extract_error_message {|{"error":""}|} = {|{"error":""}|}
  && extract_error_message {|{"error":{"message":"  "}}|} = {|{"error":{"message":"  "}}|}
;;

let%test "extract_error_message: malformed body falls back to prefix" =
  let result = extract_error_message "not json at all" in
  result = "not json at all"
;;

let%test "is_retryable: flat Ollama provider prose is not retryable" =
  (* Before the extract_error_message fix, Ollama's flat-string error
     body was returned verbatim as the full JSON blob. The extracted message
     is still provider prose, so raw HTTP classification must not infer a typed
     parser-boundary reason from it. *)
  let body = {|{"error":"Value looks like object, but can't find closing '}' symbol"}|} in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } as err ->
    not (is_retryable err)
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      } -> false
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "HTTP 400 prose does not synthesize ContextOverflow" =
  let body =
    {|{"error":{"message":"request exceeds the available context size (8192)"}}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | ContextOverflow _
  | InputCapacity _
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "HTTP 400 prompt-too-long report without ref stays Unknown InvalidRequest" =
  let body =
    {|{"error":"prompt too long; exceeded max context length by 62887 tokens"}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | ContextOverflow _
  | InputCapacity _
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "HTTP 400 prompt-too-long report with UUID ref stays unknown" =
  let body =
    {|{"error":"prompt too long; exceeded max context length by 62887 tokens (ref: 1630a4a4-998f-400a-9d54-2d87537e0c03)"}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "measured Ollama HTTP 400 prose stays unknown" =
  let body =
    {|{"error":"The prompt is too long: 1400014, model maximum context length: 1048576 (ref: 8519ccf3-5d45-4686-9ac1-64d159f75ec1)"}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "nested HTTP 400 prompt-too-long prose stays Unknown InvalidRequest" =
  let body =
    {|{"error":{"message":"prompt too long; exceeded max context length by 62887 tokens (ref: 1630a4a4-998f-400a-9d54-2d87537e0c03)"}}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | ContextOverflow _
  | InputCapacity _
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "HTTP 400 prompt-too-long report requires an ASCII token count" =
  let body =
    {|{"error":"prompt too long; exceeded max context length by many tokens (ref: 1630a4a4-998f-400a-9d54-2d87537e0c03)"}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | ContextOverflow _
  | InputCapacity _
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "HTTP 400 prompt-too-long report rejects unrelated suffixes" =
  let body =
    {|{"error":"prompt too long; exceeded max context length by 62887 tokens; retry"}|}
  in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | ContextOverflow _
  | InputCapacity _
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "HTTP 422 prompt-too-long report stays Unknown InvalidRequest" =
  let body =
    {|{"error":"prompt too long; exceeded max context length by 62887 tokens (ref: 1630a4a4-998f-400a-9d54-2d87537e0c03)"}|}
  in
  match classify_error ~retry_after_header:None ~status:422 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      }
  | ContextOverflow _
  | InputCapacity _
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "classify_error returns Unknown InvalidRequest for non-overflow 400" =
  let body = {|{"error":{"message":"bad tool schema"}}|} in
  match classify_error ~retry_after_header:None ~status:400 ~body with
  | InvalidRequest { reason = Unknown_invalid_request; _ } -> true
  | InvalidRequest
      { reason =
          Json_parse_error | Attempt_rejected
          | Request_body_refused_by_provider _ | Refusal_body_not_received
          | Unclassified_status _
      ; _
      } -> false
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "ContextOverflow is not retryable" =
  not (is_retryable (ContextOverflow { message = "overflow"; limit = Some 8192 }))
;;

let%test "InvalidRequest with malformed JSON is retryable (closing)" =
  is_retryable
    (InvalidRequest
       { message = "Value looks like object, but can't find closing '}' symbol"
       ; reason = Json_parse_error
       })
;;

let%test "InvalidRequest with malformed JSON is retryable (can't find)" =
  is_retryable
    (InvalidRequest { message = "Can't find end of string"; reason = Json_parse_error })
;;

let%test "InvalidRequest with malformed JSON is retryable (unexpected)" =
  is_retryable
    (InvalidRequest
       { message = "Unexpected character in JSON"; reason = Json_parse_error })
;;

let%test "InvalidRequest with parse error is retryable" =
  is_retryable
    (InvalidRequest { message = "Parse error at position 42"; reason = Json_parse_error })
;;

let%test "InvalidRequest with generic message is NOT retryable" =
  not
    (is_retryable
       (InvalidRequest { message = "bad tool schema"; reason = Unknown_invalid_request }))
;;

let%test "InvalidRequest with unknown field is NOT retryable" =
  not
    (is_retryable
       (InvalidRequest
          { message = "Unknown field 'foo'"; reason = Unknown_invalid_request }))
;;

let%test "InvalidRequest with uppercase PARSE ERROR is retryable" =
  is_retryable
    (InvalidRequest { message = "PARSE ERROR at position 42"; reason = Json_parse_error })
;;

let%test "InvalidRequest with MixedCase is retryable" =
  is_retryable
    (InvalidRequest
       { message = "Unexpected Character In JSON"; reason = Json_parse_error })
;;

let%test "InvalidRequest with unterminated string is retryable" =
  is_retryable
    (InvalidRequest { message = "Unterminated string literal"; reason = Json_parse_error })
;;

let%test "InvalidRequest with invalid json is retryable" =
  is_retryable
    (InvalidRequest
       { message = "invalid json in tool call arguments"; reason = Json_parse_error })
;;

let%test "InvalidRequest with query parse error is NOT retryable" =
  not
    (is_retryable
       (InvalidRequest
          { message = "parse error in query parameters"
          ; reason = Unknown_invalid_request
          }))
;;

let%test "InvalidRequest can't-find tool is NOT retryable" =
  not
    (is_retryable
       (InvalidRequest
          { message = "Can't find the specified tool"; reason = Unknown_invalid_request }))
;;

let%test "InvalidRequest with empty message is NOT retryable" =
  not (is_retryable (InvalidRequest { message = ""; reason = Unknown_invalid_request }))
;;

let%test "RateLimited retryability does not inspect provider prose" =
  is_retryable
    (RateLimited
       { retry_after = None
       ; message = "Insufficient balance or no resource package. Please recharge."
       })
;;

let%test "classify_error 429 preserves structured retry_after regardless of prose" =
  let body =
    {|{"error":{"retry_after":5.0,"message":"Insufficient balance or no resource package"}}|}
  in
  match classify_error ~retry_after_header:None ~status:429 ~body with
  | RateLimited { retry_after = Some value; _ } -> Float.equal value 5.0
  | RateLimited { retry_after = None; _ }
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "classify_error 429 transient preserves retry_after" =
  let body =
    {|{"error":{"retry_after":3.0,"message":"Too many requests, please slow down"}}|}
  in
  match classify_error ~retry_after_header:None ~status:429 ~body with
  | RateLimited { retry_after = Some ra; _ } -> Float.equal ra 3.0
  | RateLimited { retry_after = None; _ }
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

(* agent_core 429 typed completion (2026-07): incident context — ollama.com
   returned HTTP 429 with a flat-string body (no [error.retry_after]
   field) while carrying a standard [Retry-After] response header. The
   classifier must fall back to the header when the body has nothing, and
   must prefer the body when both are present (provider prose is more
   precise than a generic transport header). *)

let%test "classify_error 429: body retry_after wins over header" =
  let body = {|{"error":{"retry_after":5.0,"message":"slow down"}}|} in
  match classify_error ~status:429 ~body ~retry_after_header:(Some 30.0) with
  | RateLimited { retry_after = Some ra; message } ->
    Float.equal ra 5.0 && String.equal message "slow down"
  | RateLimited { retry_after = None; _ }
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "classify_error 429: header-only (flat provider body) works" =
  let body = {|{"error":"too many concurrent requests"}|} in
  match classify_error ~status:429 ~body ~retry_after_header:(Some 12.0) with
  | RateLimited { retry_after = Some ra; message } ->
    Float.equal ra 12.0 && String.equal message "too many concurrent requests"
  | RateLimited { retry_after = None; _ }
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "classify_error 429: neither body nor header yields None, message preserved" =
  let body = {|{"error":"too many concurrent requests"}|} in
  match classify_error ~retry_after_header:None ~status:429 ~body with
  | RateLimited { retry_after = None; message } ->
    String.equal message "too many concurrent requests"
  | RateLimited { retry_after = Some _; _ }
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | PaymentRequired _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

(* HTTP 402 Payment Required — first-class classification, not the
   Unknown_invalid_request catch-all (see PaymentRequired variant doc). *)
let%test "classify_error 402 maps to PaymentRequired" =
  let body = {|{"error":{"message":"Insufficient Balance"}}|} in
  match classify_error ~retry_after_header:None ~status:402 ~body with
  | PaymentRequired { message } -> String.equal message "Insufficient Balance"
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;

let%test "classify_error 402 is not retryable" =
  let body =
    {|{"error":{"message":"Insufficient Balance","type":"insufficient_balance_error"}}|}
  in
  match classify_error ~retry_after_header:None ~status:402 ~body with
  | PaymentRequired _ as err -> not (is_retryable err)
  | RateLimited _
  | Overloaded _
  | ServerError _
  | AuthError _
  | AuthorizationError _
  | InvalidRequest _
  | NotFound _
  | ContextOverflow _
  | InputCapacity _
  | NetworkError _
  | Connect_failed _
  | Timeout _ -> false
;;
