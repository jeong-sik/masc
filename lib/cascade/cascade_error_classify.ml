(** Cascade_error_classify — SDK error parser and substring classifier on top of
    the {!Cascade_internal_error} ADT.

    RFC-0142 Phase 2 PR-1: the [masc_internal_error] ADT, its JSON codec, the
    Prometheus accounting, and the per-variant kind/cascade_name labels were
    moved to {!Cascade_internal_error}.  This module now owns only:

    - {!admission_wait_timeout_error} — construction-site helper that logs
      and returns the [Admission_queue_timeout] variant as a [result];
    - {!parse_masc_internal_error_json} — JSON parser that turns the typed
      envelope written by [sdk_error_of_masc_internal_error] back into a
      [masc_internal_error];
    - {!classify_masc_internal_error*} — entry points for SDK errors and raw
      strings carrying the envelope;
    - {!sdk_error_is_server_rejected_parse_error} — the contained substring
      classifier described in [keeper_meta_contract.ml]; this is the canonical
      substring SSOT for "server rejected the request body".  Substring use
      here is unavoidable because the upstream payload is a raw SDK string.

    The {!Cascade_internal_error} surface (types, [masc_internal_error_to_json],
    [sdk_error_of_masc_internal_error], summaries, labels, metric name) is
    re-exported via [include] so callers that reference
    [Cascade_error_classify.masc_internal_error], [Cascade_error_classify.Cascade_exhausted],
    etc. continue to compile unchanged.

    @since God file decomposition *)

open Result.Syntax

include Cascade_internal_error

let admission_wait_timeout_error
    ~(keeper_name : string)
    ~(cascade_name : Cascade_name.t)
    ~(priority : Llm_provider.Request_priority.t)
    (wait_ms : int) =
  let wait_sec = float_of_int wait_ms /. 1000.0 in
  let cascade_name_string = Cascade_name.to_string cascade_name in
  let msg =
    Printf.sprintf
      "Admission queue wait timeout after %.1fs (wait_ms=%d, keeper=%s, cascade=%s, priority=%s)"
      wait_sec wait_ms keeper_name cascade_name_string
      (Llm_provider.Request_priority.to_string priority)
  in
  Log.Misc.warn "%s" msg;
  Error
    (sdk_error_of_masc_internal_error
       (Admission_queue_timeout { keeper_name; cascade_name; wait_sec }))

(** RFC-0142 Phase 2 PR-2: the JSON parser and SDK envelope decoders moved
    to {!Cascade_error_from_sdk}; re-exported below so callers that reference
    [Cascade_error_classify.parse_masc_internal_error_json],
    [Cascade_error_classify.classify_masc_internal_error_of_string], and
    [Cascade_error_classify.classify_masc_internal_error] compile unchanged. *)

let parse_masc_internal_error_json = Cascade_error_from_sdk.parse_masc_internal_error_json
let classify_masc_internal_error_of_string = Cascade_error_from_sdk.classify_masc_internal_error_of_string
let classify_masc_internal_error = Cascade_error_from_sdk.classify_masc_internal_error

let substring_matches_at ~(needle : string) (haystack : string) start_idx =
  let needle_len = String.length needle in
  if start_idx < 0 || start_idx + needle_len > String.length haystack
  then false
  else
    let rec loop i =
      if i >= needle_len then true
      else if String.unsafe_get needle i <> String.unsafe_get haystack (start_idx + i)
      then false
      else loop (i + 1)
    in
    loop 0

let string_contains_substring ~(needle : string) (haystack : string) =
  if String.equal needle "" then true
  else
    let max_start = String.length haystack - String.length needle in
    let rec loop i =
      if i > max_start then false
      else if substring_matches_at ~needle haystack i then true
      else loop (i + 1)
    in
    loop 0

let sdk_error_is_server_rejected_parse_error (err : Agent_sdk.Error.sdk_error) =
  match err with
  | Agent_sdk.Error.Provider (Llm_provider.Error.ParseError _) -> true
  | Agent_sdk.Error.Api (InvalidRequest { message }) ->
    let lower = String.lowercase_ascii message in
    (string_contains_substring ~needle:"can't find closing" lower
     || string_contains_substring ~needle:"find end of" lower)
    || string_contains_substring ~needle:"unexpected character in json" lower
    || string_contains_substring ~needle:"unterminated" lower
    || string_contains_substring ~needle:"parse error" lower
  | Agent_sdk.Error.Api
      ( RateLimited _
      | Overloaded _
      | ServerError _
      | AuthError _
      | NotFound _
      | ContextOverflow _
      | NetworkError _
      | Timeout _ )
  | Agent_sdk.Error.Provider _
  | Agent_sdk.Error.Agent _
  | Agent_sdk.Error.Mcp _
  | Agent_sdk.Error.Config _
  | Agent_sdk.Error.Serialization _
  | Agent_sdk.Error.Io _
  | Agent_sdk.Error.Orchestration _
  | Agent_sdk.Error.A2a _
  | Agent_sdk.Error.Internal _ -> false
