(** Cascade_error_from_sdk — Reverse-direction SDK envelope decoders for the
    [masc_internal_error] ADT.

    The forward direction (variant -> JSON, variant -> SDK error) lives in
    {!Cascade_internal_error}; this module owns the matching reverse direction:

    - {!parse_masc_internal_error_json} — JSON value produced by
      {!Cascade_internal_error.masc_internal_error_to_json} back into a
      typed variant;
    - {!classify_masc_internal_error_of_string} — raw string entry point
      that locates the [[masc_oas_error]] prefix anywhere in the text;
    - {!classify_masc_internal_error} — SDK error entry point for
      [Agent_sdk.Error.Internal] values that carry the prefix.

    RFC-0142 Phase 2 PR-2 extracted these three functions from
    {!Cascade_error_classify}; the facade in that module continues to
    re-export them so existing callers compile unchanged.

    @since RFC-0142 Phase 2 *)

open Cascade_internal_error

let canonical_masc_oas_kind kind =
  match kind with
  | "oas_timeout_budget" -> "provider_timeout"
  | _ -> kind

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
            (* If the reason payload does not round-trip through a typed
               [cascade_exhaustion_reason] variant, the entire payload is
               returned as [None] so the caller treats the SDK error as
               opaque. Synthesizing a sentinel reason here would be
               indistinguishable from a real cascade-reason value and
               poison downstream typed pattern matches. *)
            let reason_opt =
              match List.assoc_opt "reason"
                      (match json with `Assoc fields -> fields | _ -> []) with
              | Some json_val ->
                  Keeper_types.cascade_exhaustion_reason_of_json json_val
              | None -> None
            in
            (match reason_opt with
             | Some reason ->
               Some
                 (Cascade_exhausted
                    {
                      cascade_name = cascade_name_of_string cascade_name;
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
               Some
                 (Capacity_backpressure
                    {
                      cascade_name = cascade_name_of_string cascade_name;
                      source;
                      detail;
                      retry_after_sec =
                        float_opt_of_assoc "retry_after_sec" json;
                    })
             | None -> None)
          | _ -> None)
      | Some (`String "resumable_cli_session") -> (
          match string_opt_of_assoc "cascade_name" json, string_opt_of_assoc "detail" json with
          | Some cascade_name, Some detail ->
            Some
              (Resumable_cli_session
                 {
                   cascade_name = cascade_name_of_string cascade_name;
                   detail;
                   exit_code = int_opt_of_assoc "exit_code" json;
                 })
          | _ -> None)
      | Some (`String "no_tool_capable_provider") -> (
          match string_opt_of_assoc "cascade_name" json with
          | Some cascade_name ->
            Some
              (No_tool_capable_provider
                 {
                   cascade_name = cascade_name_of_string cascade_name;
                   configured_labels =
                     string_list_of_assoc "configured_labels" json;
                   required_tool_names =
                     string_list_of_assoc "required_tool_names" json;
                   provider_rejections =
                     (match
                        provider_rejections_of_assoc "provider_rejections" json
                      with
                      | [] ->
                          provider_rejection_reasons_of_assoc
                            "rejection_reasons" json
                      | provider_rejections -> provider_rejections);
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
                   cascade_name = cascade_name_of_string cascade_name;
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
      | Some (`String kind)
        when String.equal (canonical_masc_oas_kind kind) "provider_timeout" -> (
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
                   cascade_name = cascade_name_of_string cascade_name;
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
  | Agent_sdk.Error.Internal msg when String.starts_with ~prefix:masc_internal_error_prefix msg ->
    (try parse_masc_internal_error_json (Yojson.Safe.from_string
         (String.sub msg
            (String.length masc_internal_error_prefix)
            (String.length msg - String.length masc_internal_error_prefix)))
     with Yojson.Json_error _ -> None)
  | _ -> None
