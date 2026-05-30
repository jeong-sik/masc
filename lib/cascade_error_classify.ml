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
  let cascade_name_string = cascade_name_to_string cascade_name in
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

(* ── Inlined from Cascade_error_from_sdk (RFC-0142 Phase 2 PR-2) ──── *)

let parse_masc_internal_error_json (json : Yojson.Safe.t) :
    masc_internal_error option =
  let int_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Int value) -> Some value
        | Some (`Intlit value) -> int_of_string_opt value
        | _ -> None)
    | _ -> None
  in
  let float_opt_of_assoc key = function
    | `Assoc fields -> (
        match List.assoc_opt key fields with
        | Some (`Float value) -> Some value
        | Some (`Int value) -> Some (float_of_int value)
        | Some (`Intlit value) ->
            Option.map float_of_int (int_of_string_opt value)
        | _ -> None)
    | _ -> None
  in
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "kind" fields with
      | Some (`String "cascade_exhausted") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            let reason_opt =
              match List.assoc_opt "reason"
                      (match json with `Assoc fields -> fields | _ -> []) with
              | Some json_val ->
                  Keeper_meta_contract.cascade_exhaustion_reason_of_json json_val
              | None -> None
            in
            (match reason_opt with
             | Some reason ->
               Some
                 (Cascade_exhausted
                    {
                      cascade_name = Cascade_name.of_string_exn cascade_name;
                      reason;
                    })
             | None -> None)
          | None -> None)
      | Some (`String "capacity_backpressure") -> (
          match
            string_opt_of_assoc "cascade_name" json,
            string_opt_of_assoc "source" json,
            string_opt_of_assoc "detail" json
          with
          | Some cascade_name, Some source, Some detail ->
            (match capacity_backpressure_source_of_string source with
             | Some source ->
               let retry_after_synthetic =
                 match json with
                 | `Assoc fields -> (
                     match List.assoc_opt "retry_after_synthetic" fields with
                     | Some (`Bool b) -> b
                     | _ -> false)
                 | _ -> false
               in
               let retry_after =
                 match float_opt_of_assoc "retry_after_sec" json with
                 | None -> Cascade_internal_error.No_retry_hint
                 | Some s when retry_after_synthetic ->
                   Cascade_internal_error.Synthetic_default s
                 | Some s -> Cascade_internal_error.Explicit s
               in
               Some
                 (Capacity_backpressure
                    {
                      cascade_name = Cascade_name.of_string_exn cascade_name;
                      source;
                      detail;
                      retry_after;
                    })
             | None -> None)
          | _ -> None)
      | Some (`String "resumable_cli_session") -> (
          match string_opt_of_assoc "cascade_name" json, string_opt_of_assoc "detail" json with
          | Some cascade_name, Some detail ->
            Some
              (Resumable_cli_session
                 {
                   cascade_name = Cascade_name.of_string_exn cascade_name;
                   detail;
                   exit_code = int_opt_of_assoc "exit_code" json;
                 })
          | _ -> None)
      | Some (`String "no_tool_capable_provider") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            let configured_labels =
              string_list_of_assoc "configured_labels" json
            in
            let required_tool_names =
              string_list_of_assoc "required_tool_names" json
            in
            let rejections =
              match
                provider_rejections_of_assoc "provider_rejections" json
              with
              | [] ->
                provider_rejection_reasons_of_assoc
                  "rejection_reasons" json
              | provider_rejections -> provider_rejections
            in
            let detail : Keeper_meta_contract.no_tool_capable_detail =
              { configured_labels
              ; required_tool_names
              ; provider_rejections =
                  List.map (fun r -> (r.provider_label, r.reason)) rejections
              }
            in
            Some
              (Cascade_exhausted
                 {
                   cascade_name = Cascade_name.of_string_exn cascade_name;
                   reason = Keeper_meta_contract.No_tool_capable (Some detail);
                 })
          | None -> None)
      | Some (`String "accept_rejected") -> (
          match string_opt_of_assoc "scope" json, string_opt_of_assoc "reason" json with
          | Some scope, Some reason ->
            Some
              (Accept_rejected
                 {
                   scope;
                   model = string_opt_of_assoc "model" json;
                   reason;
                 })
          | _ -> None)
      | Some (`String "admission_queue_timeout") -> (
          match string_opt_of_assoc "keeper_name" json,
                string_opt_of_assoc "cascade_name" json
          with
          | Some keeper_name, Some cascade_name ->
            let wait_sec =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "wait_sec" fields with
                  | Some (`Float v) -> v
                  | _ -> 0.0)
              | _ -> 0.0
            in
            Some
              (Admission_queue_timeout
                 {
                   keeper_name;
                   cascade_name = Cascade_name.of_string_exn cascade_name;
                   wait_sec;
                 })
          | _ -> None)
      | Some (`String "admission_queue_rejected") -> (
          match string_opt_of_assoc "keeper_name" json,
                string_opt_of_assoc "reason" json
          with
          | Some keeper_name, Some reason ->
            Some (Admission_queue_rejected { keeper_name; reason })
          | _ -> None)
      | Some (`String "turn_timeout") -> (
          match json with
          | `Assoc fields -> (
              match List.assoc_opt "elapsed_sec" fields with
              | Some (`Float v) ->
                Some (Turn_timeout { elapsed_sec = v })
              | _ -> None)
          | _ -> None)
      | Some (`String "provider_timeout") -> (
          match json with
          | `Assoc fields -> (
              match
                List.assoc_opt "budget_sec" fields,
                List.assoc_opt "keeper_turn_timeout_sec" fields,
                List.assoc_opt "estimated_input_tokens" fields,
                List.assoc_opt "source" fields
              with
              | Some (`Float budget_sec),
                Some (`Float keeper_turn_timeout_sec),
                Some (`Int estimated_input_tokens),
                Some (`String source) ->
                  Some
                    (Provider_timeout
                       {
                         budget_sec;
                         keeper_turn_timeout_sec;
                         estimated_input_tokens;
                         source;
                         remaining_turn_budget_sec =
                           float_opt_of_assoc
                             "remaining_turn_budget_sec" json;
                         min_required_sec =
                           Option.value ~default:0.0
                             (float_opt_of_assoc "min_required_sec" json);
                         phase =
                           Option.value ~default:"unknown"
                             (string_opt_of_assoc "phase" json);
                       })
              | _ -> None)
          | _ -> None)
      | Some (`String "max_tokens_ceiling_violation") -> (
          match
            string_opt_of_assoc "cascade_name" json,
            int_opt_of_assoc "requested_max_tokens" json,
            int_opt_of_assoc "provider_ceiling" json
          with
          | Some cascade_name, Some requested_max_tokens, Some provider_ceiling ->
            Some
              (Max_tokens_ceiling_violation
                 {
                   cascade_name = Cascade_name.of_string_exn cascade_name;
                   requested_max_tokens;
                   provider_ceiling;
                   reason =
                     Option.value ~default:"unknown"
                       (string_opt_of_assoc "reason" json);
                 })
          | _ -> None)
      | Some (`String "ambiguous_post_commit") -> (
          match string_opt_of_assoc "original_error" json with
          | Some original_error ->
            let is_timeout =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "is_timeout" fields with
                  | Some (`Bool b) -> b
                  | _ -> false)
              | _ -> false
            in
            let tools =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt "tools" fields with
                  | Some (`List values) ->
                    values
                    |> List.filter_map (function
                         | `String value -> Some value
                         | _ -> None)
                  | _ -> [])
              | _ -> []
            in
            Some (Ambiguous_post_commit { is_timeout; tools; original_error })
          | _ -> None)
      | Some (`String "internal_unhandled_exception") -> (
          match string_opt_of_assoc "site" json,
                string_opt_of_assoc "exn_repr" json
          with
          | Some site, Some exn_repr ->
            Some (Internal_unhandled_exception { site; exn_repr })
          | _ -> None)
      | Some (`String "internal_bridge_exception") -> (
          match string_opt_of_assoc "caller" json,
                string_opt_of_assoc "exn_repr" json
          with
          | Some caller, Some exn_repr ->
            Some (Internal_bridge_exception { caller; exn_repr })
          | _ -> None)
      | Some (`String "internal_contract_rejected") -> (
          match string_opt_of_assoc "reason" json with
          | Some reason -> Some (Internal_contract_rejected { reason })
          | _ -> None)
      | _ -> None)
  | _ -> None

let classify_masc_internal_error_of_string (raw : string) :
    masc_internal_error option =
  let prefix = masc_internal_error_prefix in
  let prefix_len = String.length prefix in
  let raw_len = String.length raw in
  let rec find_prefix start =
    if start + prefix_len > raw_len then None
    else if String.sub raw start prefix_len = prefix then Some start
    else find_prefix (start + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some prefix_start ->
    let payload_start = prefix_start + prefix_len in
    let payload = String.sub raw payload_start (raw_len - payload_start) in
    (try parse_masc_internal_error_json (Yojson.Safe.from_string payload)
     with Yojson.Json_error _ -> None)

let classify_masc_internal_error (err : Agent_sdk.Error.sdk_error) :
    masc_internal_error option =
  match err with
  | Agent_sdk.Error.Internal msg -> classify_masc_internal_error_of_string msg
  | _ -> None

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
