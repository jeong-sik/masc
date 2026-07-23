(** Response, usage-trust, and inference metric helpers for [Keeper_hooks_oas]. *)

open Keeper_hooks_oas_types

module Response_shape = Agent_sdk.Response_shape

(* #9919: counter for post_tool_use_failure events.

   Replaces an earlier low-signal metric emit that produced
   degenerate 1-bit records (51 identical rows in 48h of production,
   [threshold=0.0, raw=1.0, triggered=true]).  Per keeper + per tool
   labels let dashboards and #9880 structured judgments distinguish
   which keeper-tool pairs are actually failing instead of reading a
   single undifferentiated marker. *)
let tool_use_failure_metric = Keeper_metrics.(to_string ToolUseFailure)

let record_tool_use_failure ~keeper_name ~tool_name =
  Otel_metric_store.inc_counter tool_use_failure_metric
    ~labels:[ (label_keeper, keeper_name); (label_tool, tool_name) ] ()

(* #10083 originally patched empty [response.model] leaks by recovering a
   canonical model id inside MASC.  The ownership boundary has since moved:
   OAS owns concrete provider/model identity, while keeper-facing telemetry
   records only a neutral runtime lane.  These counters remain as quality
   signals for missing or selector-like response.model values, but their
   labels never carry the concrete model id. *)
let empty_response_model_metric =
  Otel_metric_store.metric_after_turn_response_model_empty

let alias_response_model_metric =
  Otel_metric_store.metric_after_turn_response_model_alias

let empty_response_content_metric =
  Otel_metric_store.metric_after_turn_response_content_empty

(* zero_usage moved to Keeper_hooks_oas_types (intra-library file split). *)

(* telemetry_has_canonical_model_id / is_runtime_selector_alias / ms_per_second
   moved to Keeper_hooks_oas_types (intra-library file split, 2026-05-16). *)

(* #10083: keep the missing/alias observability, but return the keeper-facing
   runtime lane instead of reconstructing OAS-owned model identity. *)
let resolve_after_turn_model ~keeper_name
    ~(response : Agent_sdk.Types.api_response) =
  let raw_model = String.trim response.model in
  if String.equal raw_model "" then begin
    let source =
      let source_telemetry_resolved = "telemetry_resolved" in
      let source_unknown_source = "unknown_source" in
      if telemetry_has_canonical_model_id response.telemetry then
        source_telemetry_resolved
      else source_unknown_source
    in
    Otel_metric_store.inc_counter empty_response_model_metric
      ~labels:[ (label_keeper, keeper_name); (label_source, source) ] ();
    Log.Keeper.warn ~keeper_name:keeper_name
      "after_turn response.model empty -> runtime_lane source=%s"
      source;
    runtime_lane_label
  end else begin
    if is_runtime_selector_alias raw_model then (
      let source_telemetry_canonical = "telemetry_canonical" in
      Otel_metric_store.inc_counter alias_response_model_metric
        ~labels:
          [
            (label_keeper, keeper_name);
            (label_alias, runtime_lane_label);
            (label_source, source_telemetry_canonical);
          ]
        ();
      Log.Keeper.warn ~keeper_name:keeper_name
        "after_turn response.model selector -> runtime_lane source=%s"
        "telemetry_canonical");
    runtime_lane_label
  end

(* stop_reason_metric_label unified into
   Keeper_hooks_oas_types.stop_reason_to_label (2026-06-24): it was a
   byte-for-output-identical 9-arm match that bypassed the
   stop_reason_label_* SSOT constants by inlining their literals.  [open
   Keeper_hooks_oas_types] above brings stop_reason_to_label into scope. *)

let record_response_content_quality_metric ~keeper_name
    (response : Agent_sdk.Types.api_response) =
  let shape = Response_shape.summarize response in
  if not (Response_shape.has_deliverable_content shape) then
    let content_shape = Response_shape.content_shape response shape in
    let shape_label = Response_shape.content_shape_to_string content_shape in
    Otel_metric_store.inc_counter empty_response_content_metric
      ~labels:
        [
          (label_keeper, keeper_name);
          (label_stop_reason, stop_reason_to_label response.stop_reason);
          (label_shape, shape_label);
        ]
      ()

let tool_call_duration_bucket_metric =
  Keeper_metrics.(to_string ToolCallDurationBucket)

let tool_call_duration_bucket_bounds =
  [ 0.05, "0.05"
  ; 0.1, "0.1"
  ; 0.25, "0.25"
  ; 0.5, "0.5"
  ; 1.0, "1"
  ; 2.5, "2.5"
  ; 5.0, "5"
  ; 10.0, "10"
  ; 30.0, "30"
  ; 60.0, "60"
  ]

let record_keeper_tool_duration_bucket ~labels duration_seconds =
  let duration_seconds = max 0.0 duration_seconds in
  let emit_bucket le ~increment =
    let labels = labels @ [ "le", le ] in
    Otel_metric_store.register_counter
      ~name:tool_call_duration_bucket_metric
      ~help:tool_call_duration_bucket_metric
      ~labels
      ();
    if increment then
      Otel_metric_store.inc_counter tool_call_duration_bucket_metric ~labels ()
  in
  List.iter
    (fun (upper_bound, le) ->
       emit_bucket le ~increment:(duration_seconds <= upper_bound))
    tool_call_duration_bucket_bounds;
  emit_bucket "+Inf" ~increment:true

let classify_usage_trust ?usage () =
  let usage_reported, usage =
    match usage with
    | Some usage -> true, usage
    | None -> false, zero_usage
  in
  Keeper_usage_trust.classify ~usage_reported ~usage

let record_usage_anomaly_metrics ~keeper_name usage_trust =
  match usage_trust with
  | Keeper_usage_trust.Usage_untrusted reasons ->
    List.iter
      (fun reason ->
         Otel_metric_store.inc_counter
           Keeper_metrics.(to_string UsageAnomalies)
	           ~labels:
	             [
	               (label_keeper_name, keeper_name);
	               (label_model, runtime_lane_label);
	               (label_reason, reason);
	             ]
           ())
      reasons
  | Keeper_usage_trust.Usage_missing | Keeper_usage_trust.Usage_trusted -> ()

let record_keeper_tool_duration_metric
    ~(keeper_name : string)
    (summary : tool_execution_summary)
  : unit =
  let labels =
    [label_keeper, keeper_name
    ; label_provider, summary.provider
    ; label_tool, summary.tool_name
    ; label_outcome, summary.outcome
    ; "tool_type", Tool_telemetry.tool_type_of_name summary.tool_name
    ]
  in
  let duration_seconds = summary.duration_ms /. ms_per_second in
  Otel_metric_store.observe_histogram
    Keeper_metrics.(to_string ToolCallDuration)
    ~labels
    duration_seconds;
  record_keeper_tool_duration_bucket ~labels duration_seconds

(** Emit prompt/decode tokens-per-second histograms from an OAS turn
    response.  Safe to call with [telemetry = None] (no-op) and with
    positive [None] timing fields (per-metric no-op).  The histograms are
    labelled by [model], the coarse [provider] string derived from the
    model id, and the finer [provider_kind] reported by OAS.  Split from
    [masc_llm_inference_duration_seconds] because wall-clock latency
    mixes prefill and decode phases.

    Extracted so the after_turn hook is unit-testable without
    constructing a full [Agent_sdk.Hooks.AfterTurn] event. *)
let record_llm_tok_s_metrics
    ~(telemetry : Agent_sdk.Types.inference_telemetry option)
  : unit =
  let prompt_tok_s_opt, decode_tok_s_opt =
    match telemetry with
    | Some { timings = Some t; _ } ->
      t.prompt_per_second, t.predicted_per_second
    | _ -> None, None
  in
  let provider_kind_label = runtime_lane_label in
  let provider = runtime_lane_label in
  let labels =
    [ "model", runtime_lane_label
    ; "provider", provider
    ; "provider_kind", provider_kind_label
    ]
  in
  (match prompt_tok_s_opt with
   | Some v when v > 0.0 ->
     Otel_metric_store.observe_histogram
       Otel_metric_store.metric_llm_prompt_tok_per_sec ~labels v
   | _ -> ());
  (match decode_tok_s_opt with
   | Some v when v > 0.0 ->
     Otel_metric_store.observe_histogram
       Otel_metric_store.metric_llm_decode_tok_per_sec ~labels v
   | _ -> ())

(** Emit the after-turn wall-clock latency histogram.  A zero/negative
    [request_latency_ms] is still a telemetry quality problem, so the
    zero-latency counter remains the alertable signal; the histogram receives
    a 1ms floor to avoid "hook ran but latency count stayed zero" dashboards. *)
let record_llm_inference_latency_metric
    ~(telemetry : Agent_sdk.Types.inference_telemetry option)
  : unit =
  let labels = [("model", runtime_lane_label)] in
  Otel_metric_store.inc_counter Otel_metric_store.metric_after_turn_hook ~labels ();
  match telemetry with
  | Some t ->
    let observed_latency_ms =
      match t.request_latency_ms with
      | Some latency_ms when latency_ms > 0 -> latency_ms
      | _ ->
          Otel_metric_store.inc_counter
            Otel_metric_store.metric_after_turn_telemetry_zero_latency
            ~labels ();
          1
    in
    Otel_metric_store.observe_histogram
      Otel_metric_store.metric_llm_inference_duration
      ~labels
      (Float.of_int observed_latency_ms /. ms_per_second)
  | None ->
    Otel_metric_store.inc_counter
      Otel_metric_store.metric_after_turn_telemetry_missing
      ~labels ()

let wall_tokens_per_second
    ~(usage_missing : bool)
    ~(output_tokens : int)
    ~(telemetry : Agent_sdk.Types.inference_telemetry option)
  : float option =
  match telemetry with
  | Some t when not usage_missing && output_tokens > 0 -> (
      match t.request_latency_ms with
      | Some request_latency_ms when request_latency_ms > 0 ->
        let request_latency_ms = Float.of_int request_latency_ms in
        let latency_ms =
          match t.ttfrc_ms with
          | Some ttfrc_ms when ttfrc_ms > 0.0 && ttfrc_ms < request_latency_ms ->
            request_latency_ms -. ttfrc_ms
          | _ -> request_latency_ms
        in
        Some (Float.of_int output_tokens /. (latency_ms /. ms_per_second))
      | _ -> None)
  | _ -> None
