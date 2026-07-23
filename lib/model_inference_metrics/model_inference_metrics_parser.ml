(** Model_inference_metrics_parser — JSONL row parsers for
    {!Model_inference_metrics}.

    Owns [parse_telemetry_entry] (decisions.jsonl rows) and
    [parse_cost_entry] (costs.jsonl rows), plus the model-attribution
    helpers (runtime name canonicalization, candidate-model fallback,
    provider hints) that both parsers share. Produces internal
    {!Model_inference_metrics_entry.raw_entry} values tagged with the
    typed {!Model_inference_metrics_entry.parse_error} reason on
    failure.

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane A).
    Internal sibling module of the facade; do not call directly from
    outside the library. *)

open Model_inference_metrics_entry

(* ── Model attribution helpers ──────────────────────────── *)

let provider_opt_of_fields ~(model : string) (fields : (string * Yojson.Safe.t) list)
  : string option
  =
  let _ = model, fields in
  None
;;

let private_provider_hint_of_fields (fields : (string * Yojson.Safe.t) list) =
  let read key =
    match List.assoc_opt key fields with
    | Some (`String raw) ->
      let trimmed = String.trim raw in
      if String.equal trimmed "" then None else Some trimmed
    | _ -> None
  in
  match read "provider_kind" with
  | Some _ as provider_kind -> provider_kind
  | None -> read "provider"
;;

let runtime_model_attribution_of_fields (fields : (string * Yojson.Safe.t) list) =
  match json_string_field_opt "runtime_id" fields with
  | Some runtime_id ->
    Some ((fun s -> s) runtime_id ^ " (runtime)")
  | None ->
    (match json_string_field_opt "runtime_id" fields with
     | Some runtime_id ->
       Some ((fun s -> s) runtime_id ^ " (legacy runtime)")
     | None -> None)
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

let first_candidate_model field_sets =
  List.find_map
    (fun fields ->
       match List.assoc_opt "candidate_models" fields with
       | Some (`List (`String m :: _)) -> Some m
       | _ -> None)
    field_sets
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
         let outcome_opt = first_json_string_field_opt "outcome" [ tfields; fields ] in
         (* Check if this is an error turn (telemetry.outcome = "error") *)
         let is_error =
           match outcome_opt with
           | Some "error" -> true
           | _ -> false
         in
         if is_error
         then (
           (* Error turns: first candidate model or runtime_id. No silent
              [__error__] marker — refuse the row so caller sees the
              attribution gap typed. *)
           let model_result : (string, parse_error) result =
             match first_candidate_model model_attribution_field_sets with
             | Some model -> Ok model
             | None ->
               (match first_runtime_model_attribution model_attribution_field_sets with
                | Some model -> Ok model
                | None -> Error Missing_error_model_attribution)
           in
           match model_result with
           | Error _ as e -> e
           | Ok model ->
           let provider = provider_opt_of_fields ~model tfields in
           Ok
             { model
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
             ; fallback_applied = false
             ; cost_usd = None
             ; tool_call_count = outer_tool_call_count
             ; tools_used = outer_tools_used
             ; usage_reported = json_bool_field_opt "usage_reported" tfields
             ; telemetry_reported = json_bool_field_opt "telemetry_reported" tfields
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
           (* Success turns: full telemetry parsing.
              Model attribution is structural: prefer explicit selected/model
              fields, then fall back to the runtime route when the row proves
              the route but OAS did not surface the concrete model. This keeps
              null-model historical rows from being repeatedly dropped without
              reintroducing the old "unknown" bucket. *)
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
           let provider = provider_opt_of_fields ~model tfields in
           let tok_per_sec_raw = json_float_field_opt "tokens_per_second" tfields in
           let prompt_tok_per_sec =
             match List.assoc_opt "prompt_per_second" tfields with
             | Some (`Float f) when f > 0.0 -> Some f
             | Some (`Int n) when n > 0 -> Some (Float.of_int n)
             | _ -> None
           in
           (* hw_decode_tokens_per_second — preferred field; fall back to
              provider_tokens_per_second for backward compat. Treat explicit
              null as absent so backfill for older rows is clean. *)
           let hw_decode_tok_per_sec =
             let read key =
               match List.assoc_opt key tfields with
               | Some (`Float f) when f > 0.0 -> Some f
               | Some (`Int n) when n > 0 -> Some (Float.of_int n)
               | _ -> None
             in
             match read "hw_decode_tokens_per_second" with
             | Some _ as v -> v
             | None -> read "provider_tokens_per_second"
           in
           let peak_memory_gb =
             let read key =
               match List.assoc_opt key tfields with
               | Some (`Float f) when f > 0.0 -> Some f
               | Some (`Int n) when n > 0 -> Some (Float.of_int n)
               | _ -> None
             in
             match read "peak_memory_gb" with
             | Some _ as v -> v
             | None -> read "peak_memory"
           in
           let latency_ms = json_positive_float_field_opt "request_latency_ms" tfields in
           let input_tokens_raw = json_int_field_opt "input_tokens" tfields in
           let output_tokens_raw = json_int_field_opt "output_tokens" tfields in
           let cache_read_tokens_raw = json_int_field_opt "cache_read_tokens" tfields in
           let cache_creation_tokens_raw =
             match json_int_field_opt "cache_creation_tokens" tfields with
             | Some _ as v -> v
             | None -> json_int_field_opt "cache_creation_input_tokens" tfields
           in
           let reasoning_tokens_raw = json_int_field_opt "reasoning_tokens" tfields in
           let fallback_applied =
             match List.assoc_opt "fallback_applied" tfields with
             | Some (`Bool b) -> b
             | _ -> false
           in
           let cost_usd_raw = json_float_field_opt "cost_usd" tfields in
           (* Per-turn thinking_enabled — emitted by keeper_unified_turn's
              append_decision_record under telemetry.thinking_enabled. Treat
              explicit null or absent as None so backfill stays clean. *)
           let thinking_enabled =
             match List.assoc_opt "thinking_enabled" tfields with
             | Some (`Bool b) -> Some b
             | _ -> None
           in
           let usage_reported =
             match json_bool_field_opt "usage_reported" tfields with
             | Some _ as value -> value
             | None ->
               if
                 input_tokens_raw <> None
                 || output_tokens_raw <> None
                 || cache_read_tokens_raw <> None
                 || reasoning_tokens_raw <> None
                 || cost_usd_raw <> None
               then Some true
               else None
           in
           let usage_trust, usage_anomaly_reasons =
             infer_usage_trust_from_fields
               tfields
               ~usage_reported
               ~input_tokens:input_tokens_raw
               ~output_tokens:output_tokens_raw
           in
           let telemetry_reported =
             match json_bool_field_opt "telemetry_reported" tfields with
             | Some _ as value -> value
             | None ->
               if
                 tok_per_sec_raw <> None
                 || prompt_tok_per_sec <> None
                 || hw_decode_tok_per_sec <> None
                 || peak_memory_gb <> None
                 || latency_ms <> None
               then Some true
               else None
           in
           (* Outcome must be present. Previous code defaulted to "success",
              which silently classified parse failures as successful turns —
              CRITICAL for cost/error-rate accounting. *)
           match outcome_opt with
           | None -> Error Missing_outcome
           | Some outcome ->
           Ok
             { model
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
             ; fallback_applied
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
       | _ -> Error No_telemetry_object)
    | _ -> Error Not_assoc)
;;

(* ── costs.jsonl parser ─────────────────────────────────── *)

let read_hw_decode_tok_per_sec (fields : (string * Yojson.Safe.t) list) =
  let read key =
    match List.assoc_opt key fields with
    | Some (`Float f) when f > 0.0 -> Some f
    | Some (`Int n) when n > 0 -> Some (Float.of_int n)
    | _ -> None
  in
  match read "hw_decode_tokens_per_second" with
  | Some _ as v -> v
  | None -> read "provider_tokens_per_second"
;;

let canonical_cost_model_id ~(provider : string option) model =
  let provider_key =
    match provider with
    | None -> None
    | Some raw -> Runtime_provider_labels.canonical_provider_label raw
  in
  match provider_key with
  | None -> model
  | Some provider_key ->
    let prefix = provider_key ^ ":" in
    if String.starts_with ~prefix model then model else prefix ^ model
;;

(* Three-way decision for the costs.jsonl [usage_missing] field. Previous
   code compressed [None] (field absent) with [Some false] via [Option.value
   ~default:false]; absent now contributes a [usage_missing_field_absent]
   anomaly reason so reconciliation can see the gap. *)
type usage_missing_decision =
  | Usage_missing_reported  (* usage_missing = true *)
  | Usage_present_reported  (* usage_missing = false *)
  | Usage_missing_field_absent  (* usage_missing field not in row *)

let parse_cost_entry (json : Yojson.Safe.t) ~since_unix
  : (raw_entry, parse_error) result
  =
  match json with
  | `Assoc fields ->
    let ts =
      match Safe_ops.json_float_opt "ts_unix" json with
      | Some v -> Some v
      | None ->
        (match List.assoc_opt "timestamp" fields with
         | Some (`String s) -> Masc_domain.parse_iso8601_opt s
         | _ -> None)
    in
    (match ts with
     | None -> Error Missing_ts_unix
     | Some ts when ts < since_unix -> Error Out_of_window
     | Some ts ->
       (* Cost rows without a [model] field cannot be attributed; previous
          code defaulted to "unknown" which collapsed every such row into a
          single bucket and broke per-model cost accounting. *)
       (match json_string_field_opt "model" fields with
        | None -> Error Missing_cost_model
        | Some raw_model ->
       let provider = provider_opt_of_fields ~model:raw_model fields in
       let model =
         canonical_cost_model_id
           ~provider:(private_provider_hint_of_fields fields)
           raw_model
       in
       let usage_missing_decision =
         match json_bool_field_opt "usage_missing" fields with
         | Some true -> Usage_missing_reported
         | Some false -> Usage_present_reported
         | None -> Usage_missing_field_absent
       in
       let usage_missing =
         match usage_missing_decision with
         | Usage_missing_reported -> true
         (* Field-absent rows preserve the legacy "treat as present" behaviour
            but are surfaced via [usage_missing_field_absent] anomaly reason. *)
         | Usage_present_reported | Usage_missing_field_absent -> false
       in
       let usage_reported = not usage_missing in
       let input_tokens_raw =
         if usage_missing then None else json_int_field_opt "input_tokens" fields
       in
       let output_tokens_raw =
         if usage_missing then None else json_int_field_opt "output_tokens" fields
       in
       let cache_read_tokens_raw =
         match json_int_field_opt "cache_read_tokens" fields with
         | Some _ as v -> v
         | None -> json_int_field_opt "cache_read_input_tokens" fields
       in
       let usage_trust, base_usage_anomaly_reasons =
         infer_usage_trust_from_fields
           fields
           ~usage_reported:(Some usage_reported)
           ~input_tokens:input_tokens_raw
           ~output_tokens:output_tokens_raw
       in
       (* Surface field-absent rows as an anomaly reason so reconciliation
          can distinguish them from explicit [usage_missing = false]. *)
       let usage_anomaly_reasons =
         match usage_missing_decision with
         | Usage_missing_field_absent ->
           if List.mem "usage_missing_field_absent" base_usage_anomaly_reasons
           then base_usage_anomaly_reasons
           else base_usage_anomaly_reasons @ [ "usage_missing_field_absent" ]
         | Usage_missing_reported | Usage_present_reported ->
           base_usage_anomaly_reasons
       in
       let latency_ms = json_positive_float_field_opt "request_latency_ms" fields in
       let tok_per_sec_raw =
         match json_float_field_opt "tokens_per_second" fields with
         | Some v when v > 0.0 -> Some v
         | _ ->
           (match output_tokens_raw, latency_ms with
            | Some out, Some latency when out > 0 && latency > 0.0 ->
              Some (Float.of_int out /. (latency /. 1000.0))
            | _ -> None)
       in
       let cache_creation_tokens_raw =
         match json_int_field_opt "cache_creation_tokens" fields with
         | Some _ as v -> v
         | None -> json_int_field_opt "cache_creation_input_tokens" fields
       in
       let prompt_tok_per_sec =
         match List.assoc_opt "prompt_per_second" fields with
         | Some (`Float f) when f > 0.0 -> Some f
         | Some (`Int n) when n > 0 -> Some (Float.of_int n)
         | _ -> None
       in
       let hw_decode_tok_per_sec = read_hw_decode_tok_per_sec fields in
       let peak_memory_gb =
         match json_float_field_opt "peak_memory_gb" fields with
         | Some v when v > 0.0 -> Some v
         | _ -> None
       in
       let telemetry_reported =
         tok_per_sec_raw <> None
         || prompt_tok_per_sec <> None
         || hw_decode_tok_per_sec <> None
         || peak_memory_gb <> None
         || latency_ms <> None
       in
       Ok
         { model
         ; ts_unix = ts
         ; outcome = "success"
         ; stop_reason = None
         ; turn_lane = None
         ; tok_per_sec = tok_per_sec_raw
         ; provider
         ; prompt_tok_per_sec
         ; hw_decode_tok_per_sec
         ; peak_memory_gb
         ; thinking_enabled = None
         ; latency_ms
         ; input_tokens = input_tokens_raw
         ; output_tokens = output_tokens_raw
         ; cache_read_tokens = cache_read_tokens_raw
         ; cache_creation_tokens = cache_creation_tokens_raw
         ; reasoning_tokens = json_int_field_opt "reasoning_tokens" fields
         ; fallback_applied = false
         ; cost_usd = json_float_field_opt "cost_usd" fields
         ; tool_call_count = 0
         ; tools_used = []
         ; usage_reported = Some usage_reported
         ; telemetry_reported = Some telemetry_reported
         ; usage_trust
         ; usage_anomaly_reasons
         ; coverage_reason = None
         ; coverage_stage = Some "costs_jsonl"
         ; is_error = false
         ; streaming_ttfrc_ms = None
         ; streaming_inter_chunk_count = None
         ; streaming_inter_chunk_avg_ms = None
         }))
  | _ -> Error Not_assoc
;;
