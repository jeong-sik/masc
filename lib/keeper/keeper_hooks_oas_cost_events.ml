(** Cost ledger event helpers for [Keeper_hooks_oas]. *)

open Keeper_hooks_oas_types
open Keeper_hooks_oas_response_metrics

let cost_emit_source_metric = Otel_metric_store.metric_cost_emit_zero_source

let () =
  Otel_metric_store.register_counter
    ~name:cost_emit_source_metric
    ~help:
      "Total cost.jsonl emits where cost_usd ended up as 0.0 due to a \
       known classification path (vs an actually-zero call).  Labels: \
       source ∈ {missing_usage, untrusted_usage, unmetered_provider, \
       oas_cost_unreported, zero_token_call}.  A high \
       [oas_cost_unreported] rate means OAS did not annotate usage with cost; \
       a high [untrusted_usage] rate points at the trust classifier; a high \
       [missing_usage] rate points at the provider adapter not surfacing usage. \
       See #10318 and #13698."
    ()

let classify_cost_usd_source ~usage_missing ~usage_trusted ~runtime_unmetered
    ~cost_usd =
  if usage_missing then cost_label_usage_missing
  (* token⊥cost: an untrusted *token count* does not gate the provider's
     authoritative cost_usd. A positive cost_usd is labelled [computed] even when
     token usage is untrusted; only zero/absent cost on an untrusted turn keeps
     the [usage_untrusted] source label. Keeps the value and the source label in
     sync with [cost_status_for_event]. *)
  else if (not usage_trusted) && not (cost_usd > 0.0) then
    cost_label_usage_untrusted
  else if runtime_unmetered then cost_source_unmetered_provider
  else if cost_usd > 0.0 then cost_source_computed
  else cost_label_oas_cost_unreported

let record_cost_emit_source source =
  if not (String.equal source cost_source_computed) then
    Otel_metric_store.inc_counter cost_emit_source_metric
      ~labels:[ (label_source, source) ]
      ()

(** Append a cost event to .masc/costs.jsonl for per-task cost attribution.
    Schema matches bin/masc_cost.ml with an additional "source" field to
    distinguish automatic entries from manual CLI entries.  #10318 adds
    a [cost_usd_source] field so each row is self-describing about
    why [cost_usd] is what it is.

    Called from [after_turn] hook when a trajectory accumulator is present. *)
type assembled_cost_event_payload = {
  payload : Yojson.Safe.t;
  provider : string;
  cost_status_label : string;
  cost_status_reason_label : string;
  cost_usd_source : string;
}

let assemble_cost_event_payload
    ~(agent_name : string)
    ~(task_id : string option)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    ?(usage_missing : bool = false)
    ?usage_trust
    ?(telemetry : Agent_sdk.Types.inference_telemetry option)
    ?(model : string option)
    () : assembled_cost_event_payload =
  let int_field name = function
    | Some n -> [ (name, `Int n) ]
    | None -> []
  in
  let float_field name = function
    | Some v -> [ (name, `Float v) ]
    | None -> []
  in
  let usage_for_trust : Agent_sdk.Types.api_usage =
    {
      input_tokens;
      output_tokens;
      cache_creation_input_tokens = 0;
      cache_read_input_tokens = 0;
      cost_usd = Some cost_usd;
    }
  in
  let usage_trust =
    match usage_trust with
    | Some usage_trust -> usage_trust
    | None ->
        classify_usage_trust
          ?usage:(if usage_missing then None else Some usage_for_trust)
          ~telemetry ()
  in
  let usage_trusted = Keeper_usage_trust.is_trusted usage_trust in
  let safe_input_tokens = if usage_trusted then input_tokens else 0 in
  let safe_output_tokens = if usage_trusted then output_tokens else 0 in
  let provider = runtime_lane_label in
  let runtime_unknown = false in
  let runtime_unmetered = false in
  (* Classify cost_status from the raw cost_usd. cost_usd is the provider's
     authoritative cost field and is accounted independently of token-count
     trust (token⊥cost): a positive cost_usd yields Cost_reported (and is kept
     by the safe-value mask below) even when token usage is untrusted. Only the
     token COUNTS are zeroed for untrusted usage (safe_input/output_tokens
     above). *)
  let cost_status =
    cost_status_for_event
      ~runtime_unknown
      ~runtime_unmetered
      ~usage_missing
      ~usage_trusted
      ~input_tokens
      ~output_tokens
      ~cost_usd
  in
  (* #18460: when the response model is a runtime selector alias (e.g. "auto"),
     prefer the canonical model id from telemetry so downstream cost analysis
     can look up the actual model instead of the unresolved alias. *)
  let key_model_value =
    match canonical_model_id_of_telemetry telemetry with
    | Some canonical_id -> canonical_id
    | None -> runtime_lane_label
  in
  let default_safe_cost_usd = 0.0 in
  let safe_cost_usd =
    match cost_status with
    | Cost_reported -> cost_usd
    | Cost_known_free
    | Cost_no_tokens
    | Cost_usage_missing
    | Cost_usage_untrusted
    | Cost_runtime_unknown
    | Cost_oas_cost_unreported -> default_safe_cost_usd
  in
  let cost_status_label = cost_status_to_string cost_status in
  let cost_status_reason_label = cost_status_reason cost_status in
  let raw_usage_fields =
    if usage_missing || usage_trusted then []
    else
      [
        (key_raw_input_tokens, `Int input_tokens);
        (key_raw_output_tokens, `Int output_tokens);
        (key_raw_cost_usd, `Float cost_usd);
      ]
  in
  let telemetry_fields = match telemetry with
    | Some t ->
      int_field "reasoning_tokens" t.reasoning_tokens
      @ (match t.timings with
         | Some tm ->
           int_field "cache_n" tm.cache_n
           @ float_field "prompt_per_second" tm.prompt_per_second
           @ float_field "provider_tokens_per_second" tm.predicted_per_second
           @ float_field "hw_decode_tokens_per_second" tm.predicted_per_second
         | None -> [])
      @ float_field "peak_memory_gb" t.peak_memory_gb
      @ int_field "request_latency_ms"
          (match t.request_latency_ms with
           | Some latency_ms when latency_ms > 0 -> Some latency_ms
           | _ -> None)
    | None -> []
  in
  let wall_tok_s_fields =
    float_field "tokens_per_second"
      (if usage_trusted then
         wall_tokens_per_second ~usage_missing ~output_tokens ~telemetry
       else None)
  in
  let cost_usd_source =
    classify_cost_usd_source ~usage_missing ~usage_trusted
      ~runtime_unmetered ~cost_usd
  in
  let source_auto_trajectory = "auto_trajectory" in
  let entry = `Assoc ([
    (key_agent, `String agent_name);
    ("task_id", Json_util.string_opt_to_json task_id);
    (key_provider, `String runtime_lane_label);
    (key_model, `String key_model_value);
    (key_input_tokens, `Int safe_input_tokens);
    (key_output_tokens, `Int safe_output_tokens);
    (key_cost_usd, `Float safe_cost_usd);
    (key_cost_status, `String cost_status_label);
    (key_cost_status_reason, `String cost_status_reason_label);
    (* #10318: self-describing reason for [cost_usd]'s value. *)
    (key_cost_usd_source, `String cost_usd_source);
    (key_usage_missing, `Bool usage_missing);
    (key_timestamp, `String (Masc_domain.now_iso ()));
    (key_source, `String source_auto_trajectory);
  ]
  @ Keeper_usage_trust.json_fields usage_trust
  @ raw_usage_fields
  @ wall_tok_s_fields @ telemetry_fields) in
  {
    payload = entry;
    provider;
    cost_status_label;
    cost_status_reason_label;
    cost_usd_source;
  }

let cost_event_payload
    ~(agent_name : string)
    ~(task_id : string option)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    ?(usage_missing : bool = false)
    ?usage_trust
    ?(telemetry : Agent_sdk.Types.inference_telemetry option)
    ?(model : string option)
    () : Yojson.Safe.t =
  (assemble_cost_event_payload
     ~agent_name
     ~task_id
     ~input_tokens
     ~output_tokens
     ~cost_usd
     ~usage_missing
     ?usage_trust
     ?telemetry
     ?model
     ()).payload

(** Date-split cost ledger root inside [masc_root].  See
    [Dated_jsonl] for the [costs/YYYY-MM/DD.jsonl] layout. *)
let costs_dated_dir masc_root = Filename.concat masc_root "costs"

let emit_cost_event
    ~(masc_root : string)
    ~(agent_name : string)
    ~(task_id : string option)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    ?(usage_missing : bool = false)
    ?usage_trust
    ?(telemetry : Agent_sdk.Types.inference_telemetry option)
    ?(model : string option)
    () : unit =
  (* Tier-A perf change: previously appended to a single unbounded
     [masc_root/costs.jsonl] (14k lines, 7.5MB observed in [<base-path>/.masc]),
     so every emit grew a hot single-writer file and the reader scanned
     the entire blob.  Migrated to [Dated_jsonl] under
     [masc_root/costs/YYYY-MM/DD.jsonl] — same per-day mutex registry
     used by tracing / coverage_gap / audit appenders, so concurrent
     keepers serialise on a per-day file rather than a single global
     one.  Legacy [costs.jsonl] is left in place for read compatibility
     ([Model_inference_metrics.read_cost_entries] reads both sources
     until operators archive the legacy file). *)
  let store =
    Dated_jsonl.create ~base_dir:(costs_dated_dir masc_root) ()
  in
  let assembled =
    assemble_cost_event_payload
      ~agent_name
      ~task_id
      ~input_tokens
      ~output_tokens
      ~cost_usd
      ~usage_missing
      ?usage_trust
      ?telemetry
      ?model
      ()
  in
  Otel_metric_store.inc_counter
    Otel_metric_store.metric_cost_ledger_status
    ~labels:
      [
        (label_provider, assembled.provider);
        (label_status, assembled.cost_status_label);
        (label_reason, assembled.cost_status_reason_label);
      ]
    ();
  record_cost_emit_source assembled.cost_usd_source;
  let entry = assembled.payload in
  match Dated_jsonl.append_result store entry with
  | Ok () -> ()
  | Error msg ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string MetricEmitDropped)
      ~labels:
        [
          (label_keeper, agent_name);
          (label_site, Keeper_metric_emit_dropped_site.(to_label Cost_event_write));
        ]
      ();
    Log.Keeper.error "emit_cost_event: failed to write %s: %s"
      (Dated_jsonl.base_dir store) msg
