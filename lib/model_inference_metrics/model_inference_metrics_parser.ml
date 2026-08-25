(** Model_inference_metrics_parser — JSONL row parsers for
    {!Model_inference_metrics}.

    Owns [parse_telemetry_entry] (decisions.jsonl rows) and
    [parse_cost_entry] (date-split cost rows), plus the model-attribution
    helpers (runtime name canonicalization, provider hints) that both
    parsers share. Produces internal
    {!Model_inference_metrics_entry.raw_entry} values tagged with the
    typed {!Model_inference_metrics_entry.parse_error} reason on
    failure.

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane A).
    Internal sibling module of the facade; do not call directly from
    outside the library. *)

open Model_inference_metrics_entry

let ( let* ) = Result.bind

(* ── Model attribution helpers ──────────────────────────── *)

let provider_opt_of_fields ~(model : string) (fields : (string * Yojson.Safe.t) list)
  : string option
  =
  let _ = model, fields in
  None
;;

let runtime_model_attribution_of_fields (fields : (string * Yojson.Safe.t) list) =
  match json_string_field_opt "runtime_id" fields with
  | Some runtime_id -> Some (runtime_id ^ " (runtime)")
  | None -> None
;;

let assoc_fields_opt key fields =
  match List.assoc_opt key fields with
  | Some (`Assoc nested) -> Some nested
  | _ -> None
;;

let first_json_string_field_opt key field_sets =
  List.find_map (json_string_field_opt key) field_sets
;;

let first_runtime_model_attribution field_sets =
  List.find_map runtime_model_attribution_of_fields field_sets
;;

let success_inference_identity fields telemetry_fields =
  match
    json_string_field_opt "trace_id" fields,
    json_int_field_opt "turn_id" fields,
    json_int_field_opt "agent_core_turn_ordinal" telemetry_fields
  with
  | Some trace_id, Some keeper_turn_id, Some agent_core_turn_ordinal
    when (not (String.equal (String.trim trace_id) ""))
         && keeper_turn_id > 0
         && agent_core_turn_ordinal >= 0 ->
    Ok
      (Some
         { Cost_ledger.trace_id = trace_id
         ; keeper_turn_id
         ; agent_core_turn_ordinal
         })
  | _ -> Error Missing_success_inference_identity
;;

let required_bool_field fields key error =
  match json_bool_field_opt key fields with
  | Some value -> Ok value
  | None -> Error error
;;

(* ── decisions.jsonl parser ─────────────────────────────── *)

let parse_telemetry_entry (json : Yojson.Safe.t) ~since_unix
  : (raw_entry, parse_error) result
  =
  match Safe_ops.json_float_opt "ts_unix" json with
  | None -> Error Missing_ts_unix
  | Some ts when ts < since_unix -> Error Out_of_window
  | Some ts ->
    (match json with
    | `Assoc fields ->
      (* Read outer record fields available for both success and error turns *)
      let outer_tool_call_count =
        match List.assoc_opt "tool_call_count" fields with
        | Some (`Int n) -> n
        | _ -> 0
      in
      let outer_tools_used =
        match List.assoc_opt "tools_used" fields with
        | Some (`List xs) ->
          List.filter_map
            (function
              | `String s when String.length s > 0 -> Some s
              | _ -> None)
            xs
        | _ -> []
      in
      (match List.assoc_opt "telemetry" fields with
       | Some (`Assoc tfields) ->
         let provider_context_fields =
           match assoc_fields_opt "provider_context" fields with
           | Some provider_context -> [ provider_context ]
           | None -> []
         in
         let model_attribution_field_sets = tfields :: provider_context_fields in
         let outcome_opt = json_string_field_opt "outcome" tfields in
         (* Check if this is an error turn (telemetry.outcome = "error") *)
         let is_error =
           match outcome_opt with
           | Some "error" -> true
           | _ -> false
         in
         if is_error
         then (
           (* Error turns: attribute to the dispatched runtime_id. No silent
              [__error__] marker — refuse the row so caller sees the
              attribution gap typed. *)
           let model_result : (string, parse_error) result =
             match first_runtime_model_attribution model_attribution_field_sets with
             | Some model -> Ok model
             | None -> Error Missing_error_model_attribution
           in
           match model_result with
           | Error _ as e -> e
           | Ok model ->
           let* usage_reported =
             required_bool_field
               tfields
               "usage_reported"
               Missing_usage_reported
           in
           let* telemetry_reported =
             required_bool_field
               tfields
               "telemetry_reported"
               Missing_telemetry_reported
           in
           let provider = provider_opt_of_fields ~model tfields in
           Ok
             { model
             ; inference_identity = None
             ; ts_unix = ts
             ; outcome = "error"
             ; stop_reason = json_string_field_opt "stop_reason" tfields
             ; turn_lane = json_string_field_opt "turn_lane" tfields
             ; tok_per_sec = None
             ; provider
             ; prompt_tok_per_sec = None
             ; hw_decode_tok_per_sec = None
             ; peak_memory_gb = None
             ; thinking_enabled = None
             ; latency_ms = None
             ; input_tokens = None
             ; output_tokens = None
             ; cache_read_tokens = None
             ; cache_creation_tokens = None
             ; reasoning_tokens = None
             ; cost_usd = None
             ; tool_call_count = outer_tool_call_count
             ; tools_used = outer_tools_used
             ; usage_reported = Some usage_reported
             ; telemetry_reported = Some telemetry_reported
             ; usage_trust = json_string_field_opt "usage_trust" tfields
             ; usage_anomaly_reasons =
                 json_string_list_field "usage_anomaly_reasons" tfields
             ; coverage_reason = json_string_field_opt "coverage_reason" tfields
             ; coverage_stage = json_string_field_opt "coverage_stage" tfields
             ; is_error = true
             ; streaming_ttfrc_ms = json_float_field_opt "streaming_ttfrc_ms" tfields
             ; streaming_inter_chunk_count = json_int_field_opt "streaming_inter_chunk_count" tfields
             ; streaming_inter_chunk_avg_ms = json_float_field_opt "streaming_inter_chunk_avg_ms" tfields
             })
         else (
           (* Success turns: full telemetry parsing. Model attribution is
              structural: prefer the explicit selected/model fields, then use
              the current runtime route when AGENT_CORE did not surface a concrete
              model. *)
           let model_result : (string, parse_error) result =
             match first_json_string_field_opt "selected_model" model_attribution_field_sets with
             | Some s -> Ok s
             | _ ->
               (match first_json_string_field_opt "model_used" model_attribution_field_sets with
                | Some s -> Ok s
                | _ ->
                  (match
                     first_json_string_field_opt
                       "resolved_model_id"
                       model_attribution_field_sets
                   with
                   | Some s -> Ok s
                   | None ->
                  (match first_runtime_model_attribution model_attribution_field_sets with
                   | Some model -> Ok model
                   | None -> Error Missing_success_model)))
           in
           match model_result with
           | Error _ as e -> e
           | Ok model ->
           let* usage_reported_value =
             required_bool_field
               tfields
               "usage_reported"
               Missing_usage_reported
           in
           let* telemetry_reported_value =
             required_bool_field
               tfields
               "telemetry_reported"
               Missing_telemetry_reported
           in
           let provider = provider_opt_of_fields ~model tfields in
           let tok_per_sec_raw = json_float_field_opt "tokens_per_second" tfields in
           let prompt_tok_per_sec =
             match List.assoc_opt "prompt_per_second" tfields with
             | Some (`Float f) when f > 0.0 -> Some f
             | Some (`Int n) when n > 0 -> Some (Float.of_int n)
             | _ -> None
           in
           let hw_decode_tok_per_sec =
             match List.assoc_opt "hw_decode_tokens_per_second" tfields with
             | Some (`Float f) when f > 0.0 -> Some f
             | Some (`Int n) when n > 0 -> Some (Float.of_int n)
             | _ -> None
           in
           let peak_memory_gb =
             let read key =
               match List.assoc_opt key tfields with
               | Some (`Float f) when f > 0.0 -> Some f
               | Some (`Int n) when n > 0 -> Some (Float.of_int n)
               | _ -> None
             in
	             read "peak_memory_gb"
           in
           let latency_ms = json_positive_float_field_opt "request_latency_ms" tfields in
           let input_tokens_raw = json_int_field_opt "input_tokens" tfields in
           let output_tokens_raw = json_int_field_opt "output_tokens" tfields in
           let cache_read_tokens_raw = json_int_field_opt "cache_read_tokens" tfields in
	           let cache_creation_tokens_raw =
	             json_int_field_opt "cache_creation_tokens" tfields
	           in
           let reasoning_tokens_raw = json_int_field_opt "reasoning_tokens" tfields in
           let cost_usd_raw = json_float_field_opt "cost_usd" tfields in
           (* Per-turn thinking_enabled — emitted by keeper_unified_turn's
              append_decision_record under telemetry.thinking_enabled. Treat
              explicit null or absent as None so backfill stays clean. *)
           let thinking_enabled =
             match List.assoc_opt "thinking_enabled" tfields with
             | Some (`Bool b) -> Some b
             | _ -> None
           in
           let usage_reported = Some usage_reported_value in
           let usage_trust, usage_anomaly_reasons =
             infer_usage_trust_from_fields
               tfields
               ~usage_reported
               ~input_tokens:input_tokens_raw
               ~output_tokens:output_tokens_raw
           in
           let telemetry_reported = Some telemetry_reported_value in
           (* Outcome must be present. Previous code defaulted to "success",
              which silently classified parse failures as successful turns —
              CRITICAL for cost/error-rate accounting. *)
	           match outcome_opt with
	           | None -> Error Missing_outcome
	           | Some outcome ->
	             let inference_identity =
	               if String.equal outcome "success"
	               then success_inference_identity fields tfields
	               else Ok None
	             in
	             Result.map
	               (fun inference_identity ->
	                  { model
	             ; inference_identity
	             ; ts_unix = ts
	             ; outcome
             ; stop_reason = json_string_field_opt "stop_reason" tfields
             ; turn_lane = json_string_field_opt "turn_lane" tfields
             ; tok_per_sec = tok_per_sec_raw
             ; provider
             ; prompt_tok_per_sec
             ; hw_decode_tok_per_sec
             ; peak_memory_gb
             ; thinking_enabled
             ; latency_ms
             ; input_tokens = input_tokens_raw
             ; output_tokens = output_tokens_raw
             ; cache_read_tokens = cache_read_tokens_raw
             ; cache_creation_tokens = cache_creation_tokens_raw
             ; reasoning_tokens = reasoning_tokens_raw
             ; cost_usd = cost_usd_raw
             ; tool_call_count = outer_tool_call_count
             ; tools_used = outer_tools_used
             ; usage_reported
             ; telemetry_reported
             ; usage_trust
             ; usage_anomaly_reasons
             ; coverage_reason = json_string_field_opt "coverage_reason" tfields
             ; coverage_stage = json_string_field_opt "coverage_stage" tfields
             ; is_error = false
             ; streaming_ttfrc_ms = json_float_field_opt "streaming_ttfrc_ms" tfields
             ; streaming_inter_chunk_count = json_int_field_opt "streaming_inter_chunk_count" tfields
	             ; streaming_inter_chunk_avg_ms = json_float_field_opt "streaming_inter_chunk_avg_ms" tfields
	             })
	               inference_identity)
       | _ -> Error No_telemetry_object)
    | _ -> Error Not_assoc)
;;

(* ── date-split cost row parser ─────────────────────────── *)

let read_hw_decode_tok_per_sec (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt "hw_decode_tokens_per_second" fields with
  | Some (`Float f) when f > 0.0 -> Some f
  | Some (`Int n) when n > 0 -> Some (Float.of_int n)
  | _ -> None
;;

let parse_cost_entry (json : Yojson.Safe.t) ~since_unix
  : (raw_entry, parse_error) result
  =
  match Cost_ledger.of_json json with
  | Error error -> Error (Invalid_current_cost_row error)
  | Ok row when row.ts_unix < since_unix -> Error Out_of_window
  | Ok row ->
    let fields =
      match json with
      | `Assoc fields -> fields
      | _ -> []
    in
    let usage_reported, input_tokens, output_tokens, cost_usd =
      match row.usage with
      | Cost_ledger.Usage_missing -> false, None, None, None
      | Cost_ledger.Usage_reported { input_tokens; output_tokens; cost_usd } ->
        true, Some input_tokens, Some output_tokens, Some cost_usd
    in
    let cache_read_tokens =
      if usage_reported then json_int_field_opt "cache_read_tokens" fields else None
    in
    let cache_creation_tokens =
      if usage_reported
      then json_int_field_opt "cache_creation_tokens" fields
      else None
    in
    let usage_trust, usage_anomaly_reasons =
      infer_usage_trust_from_fields
        fields
        ~usage_reported:(Some usage_reported)
        ~input_tokens
        ~output_tokens
    in
    let latency_ms = json_positive_float_field_opt "request_latency_ms" fields in
    let tok_per_sec =
      match json_positive_float_field_opt "tokens_per_second" fields with
      | Some _ as value -> value
      | None ->
        (match output_tokens, latency_ms with
         | Some output_tokens, Some latency_ms when output_tokens > 0 ->
           Some (Float.of_int output_tokens /. (latency_ms /. 1000.0))
         | _ -> None)
    in
    let prompt_tok_per_sec =
      json_positive_float_field_opt "prompt_per_second" fields
    in
    let hw_decode_tok_per_sec = read_hw_decode_tok_per_sec fields in
    let peak_memory_gb = json_positive_float_field_opt "peak_memory_gb" fields in
    let telemetry_reported =
      tok_per_sec <> None
      || prompt_tok_per_sec <> None
      || hw_decode_tok_per_sec <> None
      || peak_memory_gb <> None
      || latency_ms <> None
    in
    Ok
      { model = row.model
      ; provider = provider_opt_of_fields ~model:row.model fields
      ; inference_identity = Cost_ledger.inference_identity row
      ; ts_unix = row.ts_unix
      ; outcome = "success"
      ; stop_reason = None
      ; turn_lane = None
      ; tok_per_sec
      ; prompt_tok_per_sec
      ; hw_decode_tok_per_sec
      ; peak_memory_gb
      ; thinking_enabled = None
      ; latency_ms
      ; input_tokens
      ; output_tokens
      ; cache_read_tokens
      ; cache_creation_tokens
      ; reasoning_tokens = json_int_field_opt "reasoning_tokens" fields
      ; cost_usd
      ; tool_call_count = 0
      ; tools_used = []
      ; usage_reported = Some usage_reported
      ; telemetry_reported = Some telemetry_reported
      ; usage_trust
      ; usage_anomaly_reasons
      ; coverage_reason = None
      ; coverage_stage = Some "cost_ledger"
      ; is_error = false
      ; streaming_ttfrc_ms = None
      ; streaming_inter_chunk_count = None
      ; streaming_inter_chunk_avg_ms = None
      }
;;
