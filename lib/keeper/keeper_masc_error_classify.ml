(** Keeper_masc_error_classify — SDK error parser and substring classifier on top of
    the {!Keeper_meta_contract} ADT.

    RFC-0142 Phase 2 PR-1: the [masc_internal_error] ADT, its JSON codec, the
    Prometheus accounting, and the per-variant kind/cascade_name labels were
    moved to {!Keeper_meta_contract}.  This module now owns only:

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

    The {!Keeper_meta_contract} surface (types, [masc_internal_error_to_json],
    [sdk_error_of_masc_internal_error], summaries, labels, metric name) is
    re-exported via [include] so callers that reference
    [Keeper_masc_error_classify.masc_internal_error], [Keeper_masc_error_classify.Cascade_exhausted],
    etc. continue to compile unchanged.

    @since God file decomposition *)

open Result.Syntax

include Keeper_meta_contract

let admission_wait_timeout_error
    ~(keeper_name : string)
    ~(cascade_name : string)
    ~(priority : Llm_provider.Request_priority.t)
    (wait_ms : int) =
  let wait_sec = float_of_int wait_ms /. 1000.0 in
  let cascade_name_string = cascade_name in
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
    to {!Keeper_error_from_sdk}; re-exported below so callers that reference
    [Keeper_masc_error_classify.parse_masc_internal_error_json],
    [Keeper_masc_error_classify.classify_masc_internal_error_of_string], and
    [Keeper_masc_error_classify.classify_masc_internal_error] compile unchanged. *)

let parse_masc_internal_error_json = Keeper_error_from_sdk.parse_masc_internal_error_json
let classify_masc_internal_error_of_string = Keeper_error_from_sdk.classify_masc_internal_error_of_string
let classify_masc_internal_error = Keeper_error_from_sdk.classify_masc_internal_error

let string_contains_substring = String_util.string_contains_substring

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
