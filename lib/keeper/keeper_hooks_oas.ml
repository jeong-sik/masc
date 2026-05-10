(** Keeper_hooks_oas — OAS hooks adapter for Keeper Agent.run().

    Maps keeper-specific behaviors (checkpoint, metrics, social events,
    safety gates) to OAS hook events.

    Safety checks in [pre_tool_use]:
    - Cost budget: reject tool calls when accumulated cost exceeds limit
    - Destructive patterns: reject bash/edit tools with dangerous commands
      (rm -rf, drop table, force push, etc.)

    These checks were previously in [Eval_gate.guarded_execute] and are
    now natively integrated into the Agent.run() hook lifecycle.

    @since Phase 4 — Keeper → Agent.run() migration
    @since Phase 7 — Eval_gate → OAS hooks migration *)


(** Keeper deny list — derived from Tool_catalog surface SSOT.
    Administrative/destructive operations that should only be invoked
    by operators or through controlled workflows.
    Inspired by Trail of Bits' deny-rule pattern. *)
let keeper_denied_tools =
  Tool_catalog.tools_for_surface Tool_catalog.Keeper_denied

(* [escape_field], [render_inline_skip_reason], [broadcast_tool_skipped],
   and [extract_command_from_input] now live in [Keeper_guards]. They
   are used only by the decomposed pre_tool_use guard chain, so keeping
   them there avoids a circular dependency and concentrates the
   gate-level concerns in one module. *)

(** Derive a provider label from a model id.

    Delegates to {!Provider_adapter.provider_of_model_label}. Explicit
    ["provider:model"] labels are trusted; bare model ids require typed OAS
    [provider_kind] telemetry and otherwise stay ["unknown"]. *)
let provider_of_model ?provider_kind (model : string) : string =
  Provider_adapter.provider_of_model_label ?provider_kind model

let provider_kind_of_telemetry
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { provider_kind = Some kind; _ } -> Some kind
  | Some _ | None -> None

let provider_of_model_with_telemetry ~model ~telemetry =
  let provider_kind = provider_kind_of_telemetry telemetry in
  provider_of_model ?provider_kind model

let structurally_unmetered_provider provider =
  Provider_adapter.is_structurally_unmetered_provider provider

let usage_has_tokens (usage : Agent_sdk.Types.api_usage) =
  usage.input_tokens > 0
  || usage.output_tokens > 0
  || usage.cache_creation_input_tokens > 0
  || usage.cache_read_input_tokens > 0

let is_keeper_board_write_tool_name tool_name =
  match Tool_name.Keeper.of_string tool_name with
  | Some tool -> Tool_name.Keeper.is_board_write tool
  | None -> false

let current_keeper_model meta =
  let m = meta.Keeper_types.runtime.usage.last_model_used in
  if m = "" then Keeper_types.cascade_name_of_meta meta else m

let stop_reason_to_label = function
  | Agent_sdk.Types.EndTurn -> "end_turn"
  | Agent_sdk.Types.StopToolUse -> "tool_use"
  | Agent_sdk.Types.MaxTokens -> "max_tokens"
  | Agent_sdk.Types.StopSequence -> "stop_sequence"
  | Agent_sdk.Types.Unknown _ -> "unknown"

let idle_severity_to_label = function
  | Agent_sdk.Hooks.Idle_severity.Nudge -> "nudge"
  | Agent_sdk.Hooks.Idle_severity.Final_warning -> "final_warning"
  | Agent_sdk.Hooks.Idle_severity.Skip -> "skip"

let idle_decision_to_label = function
  | Agent_sdk.Hooks.Continue -> "continue"
  | Agent_sdk.Hooks.Skip -> "skip"
  | Agent_sdk.Hooks.Nudge _ -> "nudge"
  | Agent_sdk.Hooks.Override _ -> "override"
  | Agent_sdk.Hooks.ApprovalRequired -> "approval_required"
  | Agent_sdk.Hooks.AdjustParams _ -> "adjust_params"
  | Agent_sdk.Hooks.ElicitInput _ -> "elicit_input"

let render_pre_tool_gate_source_hint
    (event : Keeper_guards.gate_decision_event) =
  match event.source_path, event.source_line with
  | None, None -> ""
  | Some path, None ->
    Printf.sprintf " source_path=%s" (Keeper_guards.escape_field path)
  | None, Some line -> Printf.sprintf " source_line=%d" line
  | Some path, Some line ->
    Printf.sprintf " source_path=%s source_line=%d"
      (Keeper_guards.escape_field path) line

let render_pre_tool_gate_output (event : Keeper_guards.gate_decision_event) =
  if event.decision = Keeper_guards.Gate_approval_required then
    Printf.sprintf
      "[tool_approval_required] tool=%s source=keeper_hook code=%s reason=%s%s"
      (Keeper_guards.escape_field event.tool_name)
      (Keeper_guards.escape_field event.reason_code)
      (Keeper_guards.escape_field event.reason_text)
      (render_pre_tool_gate_source_hint event)
  else
    match event.source_path, event.source_line with
    | Some source_path, Some source_line ->
      Keeper_guards.render_inline_skip_reason_with_source
        ~source_path
        ~source_line
        ~tool_name:event.tool_name
        ~reason_code:event.reason_code
        ~reason_text:event.reason_text
    | _ ->
      Keeper_guards.render_inline_skip_reason
        ~tool_name:event.tool_name
        ~reason_code:event.reason_code
        ~reason_text:event.reason_text

let pre_tool_gate_error (event : Keeper_guards.gate_decision_event) =
  let decision = Keeper_guards.gate_decision_to_string event.decision in
  Printf.sprintf "%s:%s: %s"
    decision event.reason_code event.reason_text

let trajectory_duration_ms duration_ms =
  if (not (Float.is_finite duration_ms)) || Float.compare duration_ms 0.0 <= 0
  then 0
  else max 1 (int_of_float (Float.round duration_ms))

let record_pre_tool_gate_attempt
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(tool_call_count_ref : int ref)
    ?(trajectory_acc : Trajectory.accumulator option)
    (event : Keeper_guards.gate_decision_event) =
  incr tool_call_count_ref;
  let meta = !meta_ref in
  let keeper_name = meta.name in
  let model = current_keeper_model meta in
  let safe_input = Observability_redact.redact_json_value event.input in
  let output_text = render_pre_tool_gate_output event in
  let error = pre_tool_gate_error event in
  let duration_ms = Float.max 0.0 event.stage_latency_ms in
  (try
     Keeper_tool_call_log.log_call
       ~keeper_name
       ~tool_name:event.tool_name
       ~input:safe_input
       ~output_text
       ~success:false
       ~duration_ms
       ~model
       ~result_bytes:(String.length output_text)
       ()
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_lifecycle_callback_failures
         ~labels:[("keeper", keeper_name); ("callback", "gate_tool_call_log")]
         ();
       Log.Keeper.warn
         "keeper:%s pre_tool_use gate tool_call log failed tool=%s err=%s"
         keeper_name event.tool_name (Printexc.to_string exn));
  match trajectory_acc with
  | None -> ()
  | Some acc ->
      let trace_id = acc.Trajectory.trace_id in
      let runtime_contract =
        Keeper_tool_call_log.runtime_contract_json_for_call
          ~keeper_name
          ~model
          ()
      in
      let action_radius =
        Keeper_tool_call_log.action_radius_json_for_call
          ~keeper_name
          ~tool_name:event.tool_name
          ~input:safe_input
          ~success:false
          ~duration_ms
          ~error
          ()
      in
      let now = Time_compat.now () in
      let turn = if event.turn > 0 then event.turn else acc.Trajectory.turn in
      let round =
        acc.Trajectory.entries
        |> List.filter (fun (e : Trajectory.tool_call_entry) -> e.turn = turn)
        |> List.length
        |> ( + ) 1
      in
      let entry : Trajectory.tool_call_entry =
        {
          ts = now;
          ts_iso = Masc_domain.iso8601_of_unix_seconds now;
          turn;
          round;
          tool_name = event.tool_name;
          args_json = Yojson.Safe.to_string safe_input;
          gate_decision = Trajectory.Reject error;
          result = Some output_text;
          duration_ms = trajectory_duration_ms duration_ms;
          error = Some error;
          cost_usd = 0.0;
        }
      in
      Trajectory.record_entry
        ~runtime_contract
        ~action_radius
        ~on_persist_error:(fun exn ->
          Telemetry_coverage_gap.record
            ~masc_root:acc.Trajectory.masc_root
            ~source:"trajectory_tool_call"
            ~producer:"keeper_hooks_oas.pre_tool_use"
            ~durable_store:
              (Trajectory.trajectory_path acc.Trajectory.masc_root
                 acc.Trajectory.keeper_name trace_id)
            ~dashboard_surface:"/api/v1/keepers/:name/tool-stats"
            ~stale_reason:"trajectory_append_failed"
            ~keeper_name
            ~trace_id
            ~error:(Printexc.to_string exn)
            ())
        acc
        entry

(* #9919: counter for post_tool_use_failure events.

   Replaces an earlier [Heuristic_metrics.record] emit that produced
   degenerate 1-bit records (51 identical rows in 48h of production,
   [threshold=0.0, raw=1.0, triggered=true]).  Per keeper + per tool
   labels let dashboards and #9880 governance judgments distinguish
   which keeper-tool pairs are actually failing instead of reading a
   single undifferentiated marker. *)
let tool_use_failure_metric = Keeper_metrics.metric_keeper_tool_use_failure

let record_tool_use_failure ~keeper_name ~tool_name =
  Prometheus.inc_counter tool_use_failure_metric
    ~labels:[ ("keeper", keeper_name); ("tool", tool_name) ] ()

(* #10083: some OAS transports (kimi_cli silent-failure and
   CompletionContractViolation synthetic responses) emit
   [response.model = ""].  That empty string then flows into every
   per-model counter label in this hook (after_turn_hook_total,
   masc_llm_inference_duration_seconds, pricing_catalog_miss_total)
   and contaminates per-provider aggregates — one empty-model turn
   wipes out the ability to attribute its ~50s of inference time to
   any specific provider.  The resolve helper applies a layered
   fallback (raw → telemetry canonical_model_id → named sentinel)
   and emits a labelled counter so the operator can see WHICH
   transport leaked and WHICH resolution path recovered it. *)
let empty_response_model_metric =
  Prometheus.metric_after_turn_response_model_empty

let alias_response_model_metric =
  Prometheus.metric_after_turn_response_model_alias

let unknown_model_sentinel = Provider_adapter.cn_unknown_provider

let zero_usage : Agent_sdk.Types.api_usage =
  {
    input_tokens = 0;
    output_tokens = 0;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd = None;
  }

let canonical_model_id_of_telemetry ~model
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { canonical_model_id = Some id; _ } when String.trim id <> "" ->
      String.trim id
  | _ -> model

let known_provider_model_id_of_label model =
  let trimmed = String.trim model in
  match String.index_opt trimmed ':' with
  | None -> None
  | Some idx when idx <= 0 || idx >= String.length trimmed - 1 -> None
  | Some idx ->
      let provider = provider_of_model trimmed in
      if String.equal provider "unknown" then None
      else
        Some
          (String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)
           |> String.trim)

let model_id_leaf model =
  match known_provider_model_id_of_label model with
  | Some id -> id
  | None -> String.trim model

let is_auto_model_label model =
  String.equal
    (String.lowercase_ascii (model_id_leaf model))
    "auto"

let is_unresolved_pricing_label model =
  let trimmed = String.trim model in
  String.equal trimmed ""
  || is_auto_model_label trimmed
  || String.equal trimmed unknown_model_sentinel

let canonical_model_id_opt
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { canonical_model_id = Some id; _ } ->
      let trimmed = String.trim id in
      if trimmed = "" || is_auto_model_label trimmed then None
      else Some trimmed
  | Some _ | None -> None

(* #10083: layered fallback for [response.model] empty-string leaks.
   Non-empty raw model is returned unchanged.  When empty, we consult
   the telemetry envelope's [canonical_model_id] (which OAS populates
   on well-formed transports even when the completion body omits
   [model]); if that is also missing we tag the turn
   [unknown_model_sentinel] so downstream labels remain explicit
   rather than becoming the ambiguous empty string.  Each fallback
   path emits a counter so the operator can attribute leaks per
   keeper per source. *)
let resolve_after_turn_model ~keeper_name
    ~(response : Agent_sdk.Types.api_response) =
  let raw_model = response.model in
  if String.trim raw_model <> "" then
    match canonical_model_id_opt response.telemetry with
    | Some canonical when is_auto_model_label raw_model ->
        Prometheus.inc_counter alias_response_model_metric
          ~labels:
            [
              ("keeper", keeper_name);
              ("alias", model_id_leaf raw_model);
              ("source", "telemetry_canonical");
            ]
          ();
        Log.Keeper.warn
          "keeper:%s after_turn response.model alias=%s → canonical=%s"
          keeper_name raw_model canonical;
        canonical
    | Some _ | None -> raw_model
  else begin
    let canonical = canonical_model_id_of_telemetry ~model:"" response.telemetry in
    let resolved, source =
      if String.trim canonical <> "" then canonical, "telemetry_resolved"
      else unknown_model_sentinel, "unknown_sentinel"
    in
    Prometheus.inc_counter empty_response_model_metric
      ~labels:[ ("keeper", keeper_name); ("source", source) ] ();
    Log.Keeper.warn
      "keeper:%s after_turn response.model empty → fallback=%s resolved=%s"
      keeper_name source resolved;
    resolved
  end

let context_max_of_telemetry
    (telemetry : Agent_sdk.Types.inference_telemetry option) =
  match telemetry with
  | Some { effective_context_window = Some n; _ } when n > 0 -> n
  | _ -> 0

let classify_usage_trust ?usage ~model ~telemetry () =
  let usage_reported, usage =
    match usage with
    | Some usage -> true, usage
    | None -> false, zero_usage
  in
  let provider_kind = provider_kind_of_telemetry telemetry in
  Keeper_usage_trust.classify_with_provider_kind ~provider_kind ~usage_reported ~usage
    ~model_used:model
    ~resolved_model_id:(canonical_model_id_of_telemetry ~model telemetry)
    ~context_max:(context_max_of_telemetry telemetry)

let record_usage_anomaly_metrics ~keeper_name ~model usage_trust =
  if not (Keeper_usage_trust.is_trusted usage_trust) then
    let reasons =
      match Keeper_usage_trust.reasons usage_trust with
      | [] -> [Keeper_usage_trust.to_string usage_trust]
      | reasons -> reasons
    in
    List.iter
      (fun reason ->
         Prometheus.inc_counter
           Keeper_metrics.metric_keeper_usage_anomalies
           ~labels:
             [
               ("keeper_name", keeper_name);
               ("model", model);
               ("reason", reason);
             ]
           ())
      reasons

(* #9868: use [pricing_for_model_opt] so unknown models surface as
   [None] and get a loud catalog-miss signal instead of silently
   returning $0. [pricing_for_model] (non-opt) collapses unknown into
   [zero_pricing], which is the exact "Unknown -> Permissive Default"
   anti-pattern called out in `instructions/software-development.md`
   (OAS #555 parallel). Paid providers (openai gpt-5 family, glm
   family) are missing from the upstream OAS catalog today, so this
   path is the only place the miss becomes observable. *)
let estimate_usage_cost_usd ~(model : string) (usage : Agent_sdk.Types.api_usage)
    : float =
  (* P1-6: distinguish two distinct "no price" paths so operators get
     actionable signals instead of misleading "add to pricing.ml" advice.

     1. Unresolved alias (model=auto, model=claude_code:auto, empty, unknown
        sentinel): the alias was not resolved to a canonical id before this
        call.  The root fix is ensuring telemetry always provides a
        canonical_model_id; adding "auto" to pricing.ml is wrong.  Use INFO.

     2. Genuine catalog miss (concrete model id not present in the OAS
        Pricing catalog): operators/contributors need to add the entry.
        Keep the existing WARN so the gap is visible. *)
  let pricing_unresolved_alias () =
    (* P1-6: use a distinct label value so monitoring dashboards can
       distinguish unresolved-alias events from genuine catalog misses.
       "(alias):<model>" in the model label maps to a different time series
       than "<model>" so operators can filter each case independently. *)
    Prometheus.inc_counter
      Prometheus.metric_pricing_catalog_miss
      ~labels:[("model", "(alias):" ^ model)] ();
    Log.Keeper.info
      "pricing_unresolved_alias model=%s input_tokens=%d output_tokens=%d \
       — model label is an unresolved alias (auto / sentinel / empty); cost \
       recorded as 0.0. Ensure telemetry provides canonical_model_id so the \
       alias is resolved before pricing."
      model usage.input_tokens usage.output_tokens;
    0.0
  in
  let pricing_catalog_miss () =
    Prometheus.inc_counter
      Prometheus.metric_pricing_catalog_miss
      ~labels:[("model", model)] ();
    Log.Keeper.warn
      "pricing_catalog_miss model=%s input_tokens=%d output_tokens=%d \
       — no pricing entry in Llm_provider.Pricing catalog; cost recorded \
       as 0.0 (not a true zero). Add the entry upstream in \
       agent_sdk/llm_provider/pricing.ml, then bump the OAS pin."
      model usage.input_tokens usage.output_tokens;
    0.0
  in
  if is_unresolved_pricing_label model then pricing_unresolved_alias ()
  else match Llm_provider.Pricing.pricing_for_model_opt model with
  | Some pricing ->
    Llm_provider.Pricing.estimate_cost ~pricing
      ~input_tokens:usage.input_tokens
      ~output_tokens:usage.output_tokens
      ~cache_creation_input_tokens:usage.cache_creation_input_tokens
      ~cache_read_input_tokens:usage.cache_read_input_tokens
      ()
  | None -> pricing_catalog_miss ()

type cost_status =
  | Cost_reported_or_estimated
  | Cost_known_free
  | Cost_known_unpriced_model
  | Cost_no_tokens
  | Cost_usage_missing
  | Cost_usage_untrusted
  | Cost_provider_unknown
  | Cost_unresolved_model_alias
  | Cost_unpriced_model

let cost_status_to_string = function
  | Cost_reported_or_estimated -> "priced"
  | Cost_known_free -> "known_free"
  | Cost_known_unpriced_model -> "known_unpriced_model"
  | Cost_no_tokens -> "no_tokens"
  | Cost_usage_missing -> "usage_missing"
  | Cost_usage_untrusted -> "usage_untrusted"
  | Cost_provider_unknown -> "provider_unknown"
  | Cost_unresolved_model_alias -> "unresolved_model_alias"
  | Cost_unpriced_model -> "unpriced_model"

let cost_status_reason = function
  | Cost_reported_or_estimated ->
      "provider_reported_or_pricing_catalog_estimate"
  | Cost_known_free -> "known_structurally_unmetered_or_zero_price"
  | Cost_known_unpriced_model -> "known_non_catalog_model"
  | Cost_no_tokens -> "no_billable_tokens"
  | Cost_usage_missing -> "usage_missing"
  | Cost_usage_untrusted -> "usage_untrusted"
  | Cost_provider_unknown -> "provider_unknown"
  | Cost_unresolved_model_alias -> "model_alias_unresolved"
  | Cost_unpriced_model -> "pricing_catalog_miss"

let pricing_model_leaf model =
  let trimmed = String.trim model in
  match String.rindex_opt trimmed ':' with
  | None -> trimmed
  | Some idx ->
      String.sub trimmed (idx + 1) (String.length trimmed - idx - 1)

let is_known_non_catalog_pricing_model model =
  match pricing_model_leaf model with
  | "gpt-5.3-codex-spark" -> true
  | _ -> false

let pricing_model_for_ledger ~model ~telemetry =
  match canonical_model_id_opt telemetry with
  | Some canonical when is_auto_model_label model -> canonical
  | Some canonical when String.trim model = "" -> canonical
  | Some canonical when String.equal (String.trim model) unknown_model_sentinel ->
      canonical
  | Some _ | None -> String.trim model

let model_resolution_source_for_ledger ~model ~pricing_model =
  let trimmed = String.trim model in
  if String.equal trimmed pricing_model then "raw"
  else if String.equal trimmed "" then "telemetry_canonical_empty"
  else if is_auto_model_label trimmed then "telemetry_canonical_alias"
  else if String.equal trimmed unknown_model_sentinel then
    "telemetry_canonical_unknown"
  else "raw"

let pricing_catalog_status ~pricing_model =
  if is_unresolved_pricing_label pricing_model then "alias_unresolved"
  else if is_known_non_catalog_pricing_model pricing_model then "known_unpriced"
  else match Llm_provider.Pricing.pricing_for_model_opt pricing_model with
  | Some pricing
    when pricing.input_per_million = 0.0
         && pricing.output_per_million = 0.0 ->
      "hit_free"
  | Some _ -> "hit_paid"
  | None -> "miss"

let cost_status_for_event
    ~(provider : string)
    ~(pricing_model : string)
    ~(usage_missing : bool)
    ~(usage_trusted : bool)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float) =
  if usage_missing then Cost_usage_missing
  else if not usage_trusted then Cost_usage_untrusted
  else if cost_usd > 0.0 then Cost_reported_or_estimated
  else if input_tokens <= 0 && output_tokens <= 0 then Cost_no_tokens
  else if structurally_unmetered_provider provider then Cost_known_free
  else if String.equal provider "unknown" then Cost_provider_unknown
  else if is_unresolved_pricing_label pricing_model then
    Cost_unresolved_model_alias
  else if is_known_non_catalog_pricing_model pricing_model then
    Cost_known_unpriced_model
  else
    match Llm_provider.Pricing.pricing_for_model_opt pricing_model with
    | Some pricing
      when pricing.input_per_million = 0.0
           && pricing.output_per_million = 0.0 ->
        Cost_known_free
    | Some _ -> Cost_reported_or_estimated
    | None -> Cost_unpriced_model

let cost_usd_for_usage ?provider_kind ~(model : string)
    (usage : Agent_sdk.Types.api_usage)
    : float =
  let provider = provider_of_model ?provider_kind model in
  match usage.cost_usd with
  | Some cost when cost > 0.0 -> cost
  | Some cost ->
      if
        usage_has_tokens usage
        && not (structurally_unmetered_provider provider)
      then
        estimate_usage_cost_usd ~model usage
      else
        cost
  | None ->
      if
        usage_has_tokens usage
        && not (structurally_unmetered_provider provider)
      then
        estimate_usage_cost_usd ~model usage
      else
        0.0

type tool_execution_summary =
  { tool_name : string
  ; provider : string
  ; outcome : string
  ; duration_ms : float
  }

let tool_execution_summary ~tool_name ~model ~success ~duration_ms :
    tool_execution_summary =
  { tool_name
  ; provider = provider_of_model model
  ; outcome = if success then "ok" else "error"
  ; duration_ms = max 0.0 duration_ms
  }

let record_keeper_tool_duration_metric
    ~(keeper_name : string)
    (summary : tool_execution_summary)
  : unit =
  Prometheus.observe_histogram
    Keeper_metrics.metric_keeper_tool_call_duration
    ~labels:
      [ "keeper", keeper_name
      ; "provider", summary.provider
      ; "tool", summary.tool_name
      ; "outcome", summary.outcome
      ]
    (summary.duration_ms /. 1000.0)

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
    ~(model : string)
    ~(telemetry : Agent_sdk.Types.inference_telemetry option)
  : unit =
  let prompt_tok_s_opt, decode_tok_s_opt =
    match telemetry with
    | Some { timings = Some t; _ } ->
      t.prompt_per_second, t.predicted_per_second
    | _ -> None, None
  in
  let provider_kind_label =
    match provider_kind_of_telemetry telemetry with
    | Some pk -> Llm_provider.Provider_kind.to_string pk
    | None -> "unknown"
  in
  let provider = provider_of_model_with_telemetry ~model ~telemetry in
  let labels =
    [ "model", model
    ; "provider", provider
    ; "provider_kind", provider_kind_label
    ]
  in
  (match prompt_tok_s_opt with
   | Some v when v > 0.0 ->
     Prometheus.observe_histogram
       Prometheus.metric_llm_prompt_tok_per_sec ~labels v
   | _ -> ());
  (match decode_tok_s_opt with
   | Some v when v > 0.0 ->
     Prometheus.observe_histogram
       Prometheus.metric_llm_decode_tok_per_sec ~labels v
   | _ -> ())

(** Emit the after-turn wall-clock latency histogram.  A zero/negative
    [request_latency_ms] is still a telemetry quality problem, so the
    zero-latency counter remains the alertable signal; the histogram receives
    a 1ms floor to avoid "hook ran but latency count stayed zero" dashboards. *)
let record_llm_inference_latency_metric
    ~(model : string)
    ~(telemetry : Agent_sdk.Types.inference_telemetry option)
  : unit =
  let labels = [("model", model)] in
  Prometheus.inc_counter Prometheus.metric_after_turn_hook ~labels ();
  match telemetry with
  | Some t ->
    let observed_latency_ms =
      match t.request_latency_ms with
      | Some latency_ms when latency_ms > 0 -> latency_ms
      | _ ->
          Prometheus.inc_counter
            Prometheus.metric_after_turn_telemetry_zero_latency
            ~labels ();
          1
    in
    Prometheus.observe_histogram
      Prometheus.metric_llm_inference_duration
      ~labels
      (Float.of_int observed_latency_ms /. 1000.0)
  | None ->
    Prometheus.inc_counter
      Prometheus.metric_after_turn_telemetry_missing
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
      Some
        (Float.of_int output_tokens
         /. (Float.of_int request_latency_ms /. 1000.0))
      | _ -> None)
  | _ -> None

(** #10318: classify why [cost_usd] ended up as it did so the
    ledger entry is self-describing.  Pre-fix [costs.jsonl] showed
    100% [cost_usd=0] across 1697 entries with no way to tell
    "untrusted usage zeroed it" apart from "pricing catalog miss"
    apart from "free local provider".  Each silent path collapsed
    to the same [0.0] field and the operator could only see
    "tracking is broken" without the next concrete action.

    Bounded source values:
    - [computed]              — cost > 0 written by the pricing path.
    - [missing_usage]         — no usage payload from the provider.
    - [untrusted_usage]       — usage_trust gate suppressed the value.
    - [unmetered_provider]    — local LLM (ollama, etc.); 0 by design.
    - [pricing_catalog_miss]  — model not in
                                [Llm_provider.Pricing] catalog;
                                [estimate_usage_cost_usd] returned 0.
    - [zero_token_call]       — trusted+priced but tokens=0
                                (tool-only call or empty completion). *)
let cost_emit_source_metric = Prometheus.metric_cost_emit_zero_source

let () =
  Prometheus.register_counter
    ~name:cost_emit_source_metric
    ~help:
      "Total cost.jsonl emits where cost_usd ended up as 0.0 due to a \
       known classification path (vs an actually-zero call).  Labels: \
       source ∈ {missing_usage, untrusted_usage, unmetered_provider, \
       unresolved_model_alias, known_unpriced_model, pricing_catalog_miss, \
       zero_token_call}.  A high [pricing_catalog_miss] rate is the hint \
       to add upstream OAS pricing entries; a high [untrusted_usage] rate \
       points at the trust classifier; a high [missing_usage] rate points \
       at the provider adapter not surfacing usage.  See #10318 and #13698."
    ()

let classify_cost_usd_source ~usage_missing ~usage_trusted ~provider
    ~model ~cost_usd =
  if usage_missing then "missing_usage"
  else if not usage_trusted then "untrusted_usage"
  else if structurally_unmetered_provider provider then "unmetered_provider"
  else if cost_usd > 0.0 then "computed"
  else if is_unresolved_pricing_label model then "unresolved_model_alias"
  else if is_known_non_catalog_pricing_model model then "known_unpriced_model"
  else
    match Llm_provider.Pricing.pricing_for_model_opt model with
    | None -> "pricing_catalog_miss"
    | Some _ -> "zero_token_call"

let record_cost_emit_source source =
  if not (String.equal source "computed") then
    Prometheus.inc_counter cost_emit_source_metric
      ~labels:[ ("source", source) ]
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
    ~(model : string)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    ?(usage_missing : bool = false)
    ?usage_trust
    ?(telemetry : Agent_sdk.Types.inference_telemetry option)
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
          ~model ~telemetry ()
  in
  let usage_trusted = Keeper_usage_trust.is_trusted usage_trust in
  let safe_input_tokens = if usage_trusted then input_tokens else 0 in
  let safe_output_tokens = if usage_trusted then output_tokens else 0 in
  let provider = provider_of_model_with_telemetry ~model ~telemetry in
  let pricing_model = pricing_model_for_ledger ~model ~telemetry in
  (* Classify cost_status using raw cost_usd so pricing catalog
     lookup is independent of the safe_value mask below. *)
  let cost_status =
    cost_status_for_event
      ~provider
      ~pricing_model
      ~usage_missing
      ~usage_trusted
      ~input_tokens
      ~output_tokens
      ~cost_usd
  in
  let safe_cost_usd =
    match cost_status with
    | Cost_reported_or_estimated -> cost_usd
    | Cost_known_free | Cost_no_tokens -> 0.0
    | Cost_usage_missing | Cost_usage_untrusted -> 0.0
    | Cost_provider_unknown
    | Cost_unresolved_model_alias
    | Cost_known_unpriced_model
    | Cost_unpriced_model -> 0.0
  in
  let cost_status_label = cost_status_to_string cost_status in
  let cost_status_reason_label = cost_status_reason cost_status in
  let raw_usage_fields =
    if usage_missing || usage_trusted then []
    else
      [
        ("raw_input_tokens", `Int input_tokens);
        ("raw_output_tokens", `Int output_tokens);
        ("raw_cost_usd", `Float cost_usd);
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
      ~provider ~model:pricing_model ~cost_usd
  in
  let entry = `Assoc ([
    ("agent", `String agent_name);
    ("task_id", Json_util.string_opt_to_json task_id);
    ("provider", `String provider);
    ("model", `String model);
    ("input_tokens", `Int safe_input_tokens);
    ("output_tokens", `Int safe_output_tokens);
    ("cost_usd", `Float safe_cost_usd);
    ("cost_status", `String cost_status_label);
    ("cost_status_reason", `String cost_status_reason_label);
    ("cost_pricing_model", `String pricing_model);
    ( "cost_pricing_catalog",
      `String (pricing_catalog_status ~pricing_model) );
    ( "model_resolution_source",
      `String
        (model_resolution_source_for_ledger ~model ~pricing_model) );
    (* #10318: self-describing reason for [cost_usd]'s value. *)
    ("cost_usd_source", `String cost_usd_source);
    ("usage_missing", `Bool usage_missing);
    ("timestamp", `String (Masc_domain.now_iso ()));
    ("source", `String "auto_trajectory");
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
    ~(model : string)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    ?(usage_missing : bool = false)
    ?usage_trust
    ?(telemetry : Agent_sdk.Types.inference_telemetry option)
    () : Yojson.Safe.t =
  (assemble_cost_event_payload
     ~agent_name
     ~task_id
     ~model
     ~input_tokens
     ~output_tokens
     ~cost_usd
     ~usage_missing
     ?usage_trust
     ?telemetry
     ()).payload

let emit_cost_event
    ~(masc_root : string)
    ~(agent_name : string)
    ~(task_id : string option)
    ~(model : string)
    ~(input_tokens : int)
    ~(output_tokens : int)
    ~(cost_usd : float)
    ?(usage_missing : bool = false)
    ?usage_trust
    ?(telemetry : Agent_sdk.Types.inference_telemetry option)
    () : unit =
  let path = Filename.concat masc_root "costs.jsonl" in
  let assembled =
    assemble_cost_event_payload
      ~agent_name
      ~task_id
      ~model
      ~input_tokens
      ~output_tokens
      ~cost_usd
      ~usage_missing
      ?usage_trust
      ?telemetry
      ()
  in
  Prometheus.inc_counter
    Prometheus.metric_cost_ledger_status
    ~labels:
      [
        ("provider", assembled.provider);
        ("status", assembled.cost_status_label);
        ("reason", assembled.cost_status_reason_label);
      ]
    ();
  record_cost_emit_source assembled.cost_usd_source;
  let entry = assembled.payload in
  let line = Yojson.Safe.to_string entry ^ "\n" in
  (try Fs_compat.append_file path line
   with Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_metric_emit_dropped
          ~labels:[("keeper", agent_name); ("site", "cost_event_write")]
          ();
        Log.Keeper.error "emit_cost_event: failed to write %s: %s"
          path (Printexc.to_string exn))

(** Build OAS hooks for a keeper agent.

    All keepers receive the full tool set unconditionally.
    Safety is enforced through eval_gate deny lists and these hooks:
    1. Cost budget — reject when accumulated cost exceeds limit
    2. Destructive pattern detection — reject dangerous bash/edit commands
    3. Cost event emission — auto-emit per-turn cost to .masc/costs.jsonl

    @param meta_ref Mutable ref to keeper metadata
    @param generation Current generation counter
    @param max_cost_usd Optional cost budget (rejects tool calls above limit)
    @param destructive_check Enable destructive pattern detection (default true)
    @param pre_tool_use_guard Optional callback that can short-circuit a tool
           before execution by returning an inline override response.
    @param on_tool_executed Optional callback after each tool execution
    @param trajectory_acc Optional trajectory accumulator for cost attribution

    Issue #8597 #3-5: dropped [~config], [~session], [~ctx_snapshot]. The
    closure body never read them; the docstring even admitted [ctx_snapshot]
    was "reserved, unused". State now flows through [meta_ref] (mutable) and
    the explicit callbacks (pre_tool_use_guard / on_tool_executed). *)

(** Suggest alternative tools from the keeper's allowed set that were
    NOT part of the repeated tool calls. Returns up to [max_suggestions]
    tool names, deterministically selected from the allowed set.
    This is the deterministic envelope: gathering candidates from a
    known set. The LLM (non-deterministic) decides which to use. *)
let suggest_alternatives ~(allowed_tools : string list)
    ~(repeated_tools : string list) ~(max_suggestions : int) : string list =
  let module SS = Set.Make (String) in
  let repeated_set =
    List.fold_left (fun acc t -> SS.add t acc) SS.empty repeated_tools
  in
  allowed_tools
  |> List.filter (fun t ->
       not (SS.mem t repeated_set)
       && t <> Tool_name.Keeper.to_string Tool_name.Keeper.Stay_silent)
  |> fun candidates ->
     let len = List.length candidates in
     if len <= max_suggestions then candidates
     else List.filteri (fun i _ -> i < max_suggestions) candidates

(** Pure decision logic for the on_idle hook.  Testable without Coord.config.

    Graduated response to repeated tool calls uses the configured
    [Env_config_keeper.KeeperKeepalive.idle_skip_threshold]:
    - For idle counts below [skip_at - 1]: gentle nudge suggesting alternatives
    - For idle counts at [skip_at - 1]: final warning (stronger nudge)
      suggesting [stay_silent]
    - For idle counts at or above [skip_at]: Skip (end this turn, but the
      heartbeat loop will retry next cycle)

    The [~allowed_tools] parameter enables concrete alternative suggestions
    instead of generic "try a different tool" messages. This is the
    deterministic envelope providing structured options for the
    non-deterministic LLM to choose from.

    Skip is not death. The keeper's heartbeat loop will schedule a new
    turn on the next cycle with fresh context. The key insight is that
    burning more tokens on a stuck LLM is worse than retrying later. *)
let on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns
    ~allowed_tools ~tool_names
  : Agent_sdk.Hooks.hook_decision =
  let tools_str = match tool_names with
    | [] -> "<none>"
    | names -> String.concat ", " names
  in
  let alternatives =
    suggest_alternatives ~allowed_tools ~repeated_tools:tool_names
      ~max_suggestions:5
  in
  let alt_str = match alternatives with
    | [] -> "keeper_tool_search, keeper_board_post, or stay_silent"
    | alts -> String.concat ", " alts
  in
  if consecutive_idle_turns >= skip_at then
    Agent_sdk.Hooks.Skip
  else if consecutive_idle_turns = skip_at - 1 then
    Agent_sdk.Hooks.Nudge
      (Printf.sprintf
         "FINAL WARNING: you repeated %s %d times. Next idle = turn ends. \
          Use one of these instead: %s — or call keeper_stay_silent to do nothing."
         tools_str consecutive_idle_turns alt_str)
  else
    Agent_sdk.Hooks.Nudge
      (Printf.sprintf
         "You are repeating %s without progress. \
          Available alternatives: %s."
         tools_str alt_str)

(** Wrapper around {!on_idle_decision_with_threshold} that supplies the
    [idle_skip_threshold] constant from [Env_config_keeper.KeeperKeepalive].
    Reads the keeper's allowed tool names from [meta_ref] for concrete
    alternative suggestions. *)
let on_idle_decision ~consecutive_idle_turns ~allowed_tools ~tool_names
  : Agent_sdk.Hooks.hook_decision =
  let skip_at = Env_config_keeper.KeeperKeepalive.idle_skip_threshold in
  on_idle_decision_with_threshold ~skip_at ~consecutive_idle_turns
    ~allowed_tools ~tool_names

let keeper_idle_decision ~meta_ref ~consecutive_idle_turns ~tool_names =
  let allowed_tools =
    Keeper_tool_policy.keeper_allowed_tool_names !meta_ref in
  let decision =
    on_idle_decision ~consecutive_idle_turns ~tool_names
      ~allowed_tools in
  let tools_str = match tool_names with
    | [] -> "<none>" | names -> String.concat ", " names in
  (match decision with
   | Agent_sdk.Hooks.Skip ->
     Log.Keeper.warn "keeper:%s idle_turns=%d repeated_tools=[%s] — requesting stop"
       (!meta_ref).name consecutive_idle_turns tools_str
   | Agent_sdk.Hooks.Nudge _ ->
     Log.Keeper.info "keeper:%s idle_turns=%d tools=[%s] — nudging LLM via Nudge"
       (!meta_ref).name consecutive_idle_turns tools_str
   | _ -> ());
  decision

let recent_tool_streak_count ?(within_sec = 900.0) ~(tool_name : string)
    (entries : Yojson.Safe.t list) : int =
  let now = Time_compat.now () in
  let rec loop count = function
    | [] -> count
    | entry :: rest ->
      (match Safe_ops.json_string_opt "tool" entry,
              Safe_ops.json_float_opt "ts" entry with
       | Some logged_tool, Some ts
         when String.equal logged_tool tool_name && now -. ts <= within_sec ->
           loop (count + 1) rest
       | _ -> count)
  in
  loop 0 (List.rev entries)

type pr_review_action_metric_event = {
  action : string;
  pr_number : int option;
  comment_id : int option;
  success : bool;
  route_via : string option;
  credential : Yojson.Safe.t option;
  identity_attestation : Yojson.Safe.t option;
}

type pr_work_action_metric_event = {
  work_action : string;
  work_source : string;
  work_ref : string option;
  pr_url : string option;
  command : string option;
  success : bool;
  route_via : string option;
}

let normalize_pr_review_action raw =
  let trimmed = String.trim raw |> String.uppercase_ascii in
  match trimmed with
  | "COMMENT" | "APPROVE" | "REQUEST_CHANGES" | "REPLY" -> Some trimmed
  | _ -> None

let json_int_opt key json = Safe_ops.json_int_opt key json

let first_some a b =
  match a with
  | Some _ -> a
  | None -> b

let observe_output_parse_failure ~surface ~output_bytes =
  Safe_ops.protect ~default:() (fun () ->
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_oas_hook_output_parse_failures
        ~labels:[ ("surface", surface) ] ());
  Safe_ops.protect ~default:() (fun () ->
      Log.Keeper.warn
        "keeper_hooks_oas output JSON parse failed: surface=%s output_bytes=%d"
        surface output_bytes)

let find_substring_from text ~needle ~start =
  let text_len = String.length text in
  let needle_len = String.length needle in
  let rec loop i =
    if needle_len = 0 then Some i
    else if i + needle_len > text_len then None
    else if String.sub text i needle_len = needle then Some i
    else loop (i + 1)
  in
  loop start

let strip_fence_language block =
  let block = String.trim block in
  match String.index_opt block '\n' with
  | None -> block
  | Some first_line_end ->
      let first_line =
        String.sub block 0 first_line_end
        |> String.trim
        |> String.lowercase_ascii
      in
      let rest =
        String.sub block (first_line_end + 1)
          (String.length block - first_line_end - 1)
        |> String.trim
      in
      if first_line = "json" || first_line = "jsonc" then rest else block

let fenced_json_candidates text =
  let fence = "```" in
  let rec loop start acc =
    match find_substring_from text ~needle:fence ~start with
    | None -> List.rev acc
    | Some open_at ->
        let content_start = open_at + String.length fence in
        (match find_substring_from text ~needle:fence ~start:content_start with
         | None -> List.rev acc
         | Some close_at ->
             let raw =
               String.sub text content_start (close_at - content_start)
               |> strip_fence_language
             in
             let acc = if raw = "" then acc else raw :: acc in
             loop (close_at + String.length fence) acc)
  in
  loop 0 []

let json_close_for_open = function
  | '{' -> Some '}'
  | '[' -> Some ']'
  | _ -> None

let balanced_json_candidates text =
  let len = String.length text in
  let rec finish_candidate i in_string escaped stack =
    if i >= len then None
    else
      let ch = text.[i] in
      if in_string then
        if escaped then finish_candidate (i + 1) true false stack
        else
          match ch with
          | '\\' -> finish_candidate (i + 1) true true stack
          | '"' -> finish_candidate (i + 1) false false stack
          | _ -> finish_candidate (i + 1) true false stack
      else
        match ch with
        | '"' -> finish_candidate (i + 1) true false stack
        | '{' | '[' ->
            (match json_close_for_open ch with
             | None -> finish_candidate (i + 1) false false stack
             | Some close ->
                 finish_candidate (i + 1) false false (close :: stack))
        | '}' | ']' ->
            (match stack with
             | close :: rest when close = ch ->
                 if rest = [] then Some i
                 else finish_candidate (i + 1) false false rest
             | _ -> None)
        | _ -> finish_candidate (i + 1) false false stack
  in
  let rec loop i acc =
    if i >= len then List.rev acc
    else
      match json_close_for_open text.[i] with
      | None -> loop (i + 1) acc
      | Some expected ->
          (match finish_candidate (i + 1) false false [ expected ] with
           | None -> loop (i + 1) acc
           | Some close_at ->
               let candidate =
                 String.sub text i (close_at - i + 1)
                 |> String.trim
               in
               loop (close_at + 1) (candidate :: acc))
  in
  loop 0 []

let parse_json_candidate ~surface candidate =
  Safe_ops.parse_json_safe
    ~context:("Keeper_hooks_oas." ^ surface ^ ".output.embedded")
    candidate

let output_json_opt ~surface output_text =
  match
    Safe_ops.parse_json_safe
      ~context:("Keeper_hooks_oas." ^ surface ^ ".output")
      output_text
  with
  | Ok json -> Some json
  | Error _ ->
      let candidates =
        fenced_json_candidates output_text @ balanced_json_candidates output_text
      in
      (match
         List.find_map
           (fun candidate ->
              match parse_json_candidate ~surface candidate with
              | Ok json -> Some json
              | Error _ -> None)
           candidates
       with
       | Some json -> Some json
       | None ->
           observe_output_parse_failure ~surface
             ~output_bytes:(String.length output_text);
           None)

let normalized_route_via raw =
  let value = String.trim raw |> String.lowercase_ascii in
  if value = "" then None else Some value

let assoc_field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let route_via_of_json json =
  let direct key =
    match assoc_field key json with
    | Some (`String value) -> normalized_route_via value
    | _ -> None
  in
  let nested parent key =
    match assoc_field parent json with
    | Some nested_json ->
        (match assoc_field key nested_json with
         | Some (`String value) -> normalized_route_via value
         | _ -> None)
    | None -> None
  in
  [
    direct "via";
    direct "execution_via";
    direct "route_via";
    nested "route" "via";
    nested "route" "execution_via";
    nested "route" "route_via";
    nested "metadata" "via";
    nested "metadata" "execution_via";
    nested "metadata" "route_via";
    nested "tool_metadata" "via";
    nested "tool_metadata" "execution_via";
    nested "tool_metadata" "route_via";
  ]
  |> List.find_map Fun.id

let non_empty_string_opt = function
  | Some value ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
  | None -> None

let string_field_opt key json = Safe_ops.json_string_opt key json |> non_empty_string_opt

let nested_string_field_opt parent key json =
  match assoc_field parent json with
  | Some nested_json -> string_field_opt key nested_json
  | None -> None

let github_pr_url_from_text raw =
  let normalized =
    raw
    |> String.map (function
         | '\n' | '\r' | '\t' | '"' | '\'' -> ' '
         | ch -> ch)
  in
  normalized
  |> String.split_on_char ' '
  |> List.find_map (fun token ->
       let token = String.trim token in
       if
         String.starts_with ~prefix:"https://github.com/" token
         && String_util.contains_substring token "/pull/"
       then Some token
       else None)

let pr_url_of_json json =
  [
    string_field_opt "pr_url" json;
    string_field_opt "pull_request_url" json;
    string_field_opt "url" json;
    string_field_opt "html_url" json;
    string_field_opt "output" json;
    nested_string_field_opt "result" "pr_url" json;
    nested_string_field_opt "result" "pull_request_url" json;
    nested_string_field_opt "result" "url" json;
    nested_string_field_opt "result" "html_url" json;
    nested_string_field_opt "result" "output" json;
    nested_string_field_opt "route_evidence" "pr_url" json;
  ]
  |> List.find_map (function
       | None -> None
       | Some value -> github_pr_url_from_text value)

let pr_create_ref_of_input input =
  [
    string_field_opt "head" input;
    string_field_opt "branch" input;
    string_field_opt "head_ref" input;
  ]
  |> List.find_map Fun.id

let command_input_of_tool ~(tool_name : string) (input : Yojson.Safe.t) =
  match tool_name with
  | "keeper_shell" ->
      let op =
        Safe_ops.json_string ~default:"" "op" input
        |> String.trim |> String.lowercase_ascii
      in
      if op = "gh" then
        Safe_ops.json_string_opt "cmd" input
        |> Option.map (fun cmd -> "gh " ^ String.trim cmd)
      else None
  | "keeper_bash" ->
      Safe_ops.json_string_opt "cmd" input
  | "masc_code_shell" ->
      Safe_ops.json_string_opt "command" input
  | _ -> None

let output_command_of_json = function
  | Some json -> Safe_ops.json_string_opt "command" json
  | None -> None

let command_candidates_of_tool_io ~tool_name ~input ~output_json =
  let add_candidate candidate acc =
    match candidate with
    | None -> acc
    | Some value ->
        let command = String.trim value in
        if command = "" || List.mem command acc then acc else acc @ [ command ]
  in
  []
  |> add_candidate (command_input_of_tool ~tool_name input)
  |> add_candidate (output_command_of_json output_json)

let shell_words_prefix ?(max_words = 8) command =
  let len = String.length command in
  let buf = Buffer.create 32 in
  let push acc =
    if Buffer.length buf = 0 then acc
    else
      let word = Buffer.contents buf in
      Buffer.clear buf;
      word :: acc
  in
  let rec loop acc i in_single in_double escaped =
    if i >= len || List.length acc >= max_words then List.rev (push acc)
    else
      let c = command.[i] in
      if escaped then (
        Buffer.add_char buf c;
        loop acc (i + 1) in_single in_double false)
      else
        match c with
        | '\\' when not in_single ->
            loop acc (i + 1) in_single in_double true
        | '\'' when not in_double ->
            loop acc (i + 1) (not in_single) in_double false
        | '"' when not in_single ->
            loop acc (i + 1) in_single (not in_double) false
        | ' ' | '\t' | '\r' | '\n' when (not in_single) && not in_double ->
            let acc = push acc in
            loop acc (i + 1) in_single in_double false
        | _ ->
            Buffer.add_char buf c;
            loop acc (i + 1) in_single in_double false
  in
  loop [] 0 false false false

let gh_argv_of_segment segment =
  match Keeper_gh_shared.parse_simple_gh_command segment with
  | Ok cmd -> Some (Keeper_gh_shared.gh_simple_command_argv cmd)
  | Error _ ->
      (match shell_words_prefix segment with
       | bin :: args when String.equal (String.lowercase_ascii bin) "gh" ->
           Some args
       | _ -> None)

let gh_pr_review_action_of_command command =
  match gh_argv_of_segment command with
  | Some (subcommand :: action :: pr_number :: args)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "review" ->
      let has_flag flag =
        List.exists
          (fun arg -> String.equal (String.lowercase_ascii arg) flag)
          args
      in
      let action =
        if has_flag "--approve" then Some "APPROVE"
        else if has_flag "--request-changes" then Some "REQUEST_CHANGES"
        else if has_flag "--comment" then Some "COMMENT"
        else None
      in
      Option.map (fun action -> (action, int_of_string_opt pr_number)) action
  | Some (subcommand :: action :: pr_number :: _)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "comment" ->
      Some ("COMMENT", int_of_string_opt pr_number)
  | _ -> None

let assoc_json_opt key json =
  match assoc_field key json with
  | Some (`Assoc _ as value) -> Some value
  | _ -> None

let output_success ~transport_success = function
  | Some json ->
      (match Safe_ops.json_bool_opt "ok" json with
       | Some value -> value
       | None ->
           let status =
             Safe_ops.json_string ~default:"" "status" json
             |> String.trim |> String.lowercase_ascii
           in
           if status = "ok" then true else transport_success)
  | None -> transport_success

let pr_review_action_metric_event_of_tool_io
    ~route_via_fallback
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool) =
  match tool_name with
  | "keeper_pr_review_comment" ->
      let output_json = output_json_opt ~surface:"pr_review_action" output_text in
      let route_via =
        first_some (Option.bind output_json route_via_of_json)
          route_via_fallback
      in
      let action =
        match output_json with
        | Some json -> Safe_ops.json_string_opt "event" json
        | None -> None
      in
      let action =
        match action with
        | Some value -> Some value
        | None -> Safe_ops.json_string_opt "event" input
      in
      let success =
        output_success ~transport_success output_json
      in
      let credential = Option.bind output_json (assoc_json_opt "credential") in
      let identity_attestation =
        Option.bind output_json (assoc_json_opt "identity_attestation")
      in
      Option.map
        (fun action ->
           {
             action;
             pr_number =
               first_some
                 (first_some
                    (match output_json with
                     | Some json -> json_int_opt "pr_number" json
                     | None -> None)
                    (json_int_opt "pr_number" input))
                 (json_int_opt "number" input);
             comment_id = None;
             success;
             route_via;
             credential;
             identity_attestation;
           })
        (Option.bind action normalize_pr_review_action)
  | "keeper_pr_review_reply" ->
      let output_json = output_json_opt ~surface:"pr_review_action" output_text in
      let route_via =
        first_some (Option.bind output_json route_via_of_json)
          route_via_fallback
      in
      let success =
        output_success ~transport_success output_json
      in
      let credential = Option.bind output_json (assoc_json_opt "credential") in
      let identity_attestation =
        Option.bind output_json (assoc_json_opt "identity_attestation")
      in
      Some
        {
          action = "REPLY";
          pr_number =
            first_some
              (first_some
                 (match output_json with
                  | Some json -> json_int_opt "pr_number" json
                  | None -> None)
                 (json_int_opt "pr_number" input))
              (json_int_opt "number" input);
          comment_id =
            first_some
              (match output_json with
               | Some json -> json_int_opt "comment_id" json
               | None -> None)
              (json_int_opt "comment_id" input);
          success;
          route_via;
          credential;
          identity_attestation;
        }
  | "keeper_shell" ->
      let output_json = output_json_opt ~surface:"pr_review_action" output_text in
      let route_via =
        first_some (Option.bind output_json route_via_of_json)
          route_via_fallback
      in
      let success =
        output_success ~transport_success output_json
      in
      command_candidates_of_tool_io ~tool_name ~input ~output_json
      |> List.find_map gh_pr_review_action_of_command
      |> Option.map (fun (action, pr_number) ->
           {
             action;
             pr_number;
             comment_id = None;
             success;
             route_via;
             credential = None;
             identity_attestation = None;
           })
  | _ -> None

let split_top_level_command_segments command =
  let len = String.length command in
  let push_segment unconditional start stop acc =
    let segment = String.sub command start (stop - start) |> String.trim in
    if segment = "" then acc else (unconditional, segment) :: acc
  in
  let rec loop acc unconditional start i in_single in_double escaped =
    if i >= len then List.rev (push_segment unconditional start len acc)
    else
      let c = command.[i] in
      if escaped then loop acc unconditional start (i + 1) in_single in_double false
      else
        match c with
        | '\\' when not in_single ->
            loop acc unconditional start (i + 1) in_single in_double true
        | '\'' when not in_double ->
            loop acc unconditional start (i + 1) (not in_single) in_double false
        | '"' when not in_single ->
            loop acc unconditional start (i + 1) in_single (not in_double) false
        | '&' when (not in_single) && (not in_double) && i + 1 < len
                   && command.[i + 1] = '&' ->
            let acc = push_segment unconditional start i acc in
            loop acc false (i + 2) (i + 2) in_single in_double false
        | '|' when (not in_single) && (not in_double) && i + 1 < len
                   && command.[i + 1] = '|' ->
            let acc = push_segment unconditional start i acc in
            loop acc false (i + 2) (i + 2) in_single in_double false
        | '\n' when (not in_single) && not in_double ->
            let acc = push_segment unconditional start i acc in
            loop acc true (i + 1) (i + 1) in_single in_double false
        | ';' when (not in_single) && not in_double ->
            let acc = push_segment unconditional start i acc in
            loop acc true (i + 1) (i + 1) in_single in_double false
        | _ ->
            loop acc unconditional start (i + 1) in_single in_double false
  in
  loop [] true 0 0 false false false

let pr_work_action_of_git_action raw =
  match String.trim raw |> String.lowercase_ascii with
  | "add" -> Some "GIT_ADD"
  | "commit" -> Some "GIT_COMMIT"
  | "push" -> Some "GIT_PUSH"
  | _ -> None

let pr_work_actions_of_git_segment segment =
  match Masc_exec_bash_parser.Bash.parse_string segment with
  | Masc_exec.Parsed.Parsed (Masc_exec.Shell_ir.Simple simple)
    when String.equal
           (Masc_exec.Bin.to_string simple.bin |> String.lowercase_ascii)
           "git" ->
      (match simple.args with
       | Masc_exec.Shell_ir.Lit action :: _ ->
           pr_work_action_of_git_action action |> Option.to_list
       | _ -> [])
  | _ ->
      let lower = String.trim segment |> String.lowercase_ascii in
      let starts_with_word prefix =
        String.equal lower prefix
        || (String.length lower > String.length prefix
            && String.starts_with ~prefix:(prefix ^ " ") lower)
      in
      if starts_with_word "git push" then [ "GIT_PUSH" ]
      else if starts_with_word "git commit" then [ "GIT_COMMIT" ]
      else if starts_with_word "git add" then [ "GIT_ADD" ]
      else []

let pr_work_actions_of_gh_segment segment =
  match gh_argv_of_segment segment with
  | Some (subcommand :: action :: _)
    when String.equal (String.lowercase_ascii subcommand) "pr"
         && String.equal (String.lowercase_ascii action) "create" ->
      [ "PR_CREATE" ]
  | _ -> []

let pr_work_actions_of_command command =
  split_top_level_command_segments command
  |> List.concat_map (fun (unconditional, segment) ->
       (* Shell conditionals can skip later segments at runtime.  Without
          per-segment exit data, count only top-level segments that are
          unconditionally reached. *)
       if not unconditional then []
       else
         match pr_work_actions_of_gh_segment segment with
         | [] -> pr_work_actions_of_git_segment segment
         | actions -> actions)

let pr_work_action_metric_events_of_tool_io
    ~route_via_fallback
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool) =
  let output_json = output_json_opt ~surface:"pr_work_action" output_text in
  let route_via =
    first_some (Option.bind output_json route_via_of_json)
      route_via_fallback
  in
  let success = output_success ~transport_success output_json in
  match tool_name with
  | "masc_code_git" ->
      let action =
        match output_json with
        | Some json -> Safe_ops.json_string_opt "action" json
        | None -> None
      in
      let action =
        match action with
        | Some value -> Some value
        | None -> Safe_ops.json_string_opt "action" input
      in
      (match Option.bind action pr_work_action_of_git_action with
       | None -> []
       | Some work_action ->
           [
             {
               work_action;
               work_source = "masc_code_git";
               work_ref = None;
               pr_url = None;
               command = None;
               success;
               route_via;
             };
           ])
  | "keeper_pr_create" ->
      let work_ref = pr_create_ref_of_input input in
      let pr_url = Option.bind output_json pr_url_of_json in
      [
        {
          work_action = "PR_CREATE";
          work_source = "keeper_pr_create";
          work_ref;
          pr_url;
          command = None;
          success;
          route_via;
        };
      ]
  | "keeper_shell" | "keeper_bash" | "masc_code_shell" ->
      command_candidates_of_tool_io ~tool_name ~input ~output_json
      |> List.concat_map (fun command ->
           pr_work_actions_of_command command
           |> List.map (fun work_action ->
                ( command,
                  {
                    work_action;
                    work_source = tool_name;
                    work_ref = None;
                    pr_url = None;
                    command = Some command;
                    success;
                    route_via;
                  } )))
      |> List.fold_left
           (fun (seen, events) (_command, event) ->
              let key = event.work_action in
              if List.mem key seen then (seen, events)
              else (key :: seen, events @ [ event ]))
           ([], [])
      |> snd
  | _ -> []

let append_pr_review_action_metric
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(generation : int)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool)
    ~(duration_ms : float)
    () =
  let route_via_fallback =
    match meta.sandbox_profile, tool_name with
    | Docker, ("keeper_pr_review_comment" | "keeper_pr_review_reply") ->
        Some "brokered"
    | Docker, "keeper_shell" ->
        if Env_config_keeper.KeeperSandbox.hard_mode () then Some "brokered"
        else Some "docker"
    | _ -> None
  in
  match
    pr_review_action_metric_event_of_tool_io
      ~route_via_fallback ~tool_name ~input ~output_text ~transport_success
  with
  | None -> ()
  | Some event ->
      let now = Time_compat.now () in
      let store = Keeper_types.keeper_pr_action_metrics_store config meta.name in
      let route_fields =
        match event.route_via with
        | None -> []
        | Some via -> [("via", `String via); ("route_via", `String via)]
      in
      let identity_fields =
        []
        |> (fun fields ->
             match event.credential with
             | None -> fields
             | Some credential -> ("credential", credential) :: fields)
        |> (fun fields ->
             match event.identity_attestation with
             | None -> fields
             | Some attestation -> ("identity_attestation", attestation) :: fields)
        |> List.rev
      in
      let snapshot =
        `Assoc
          ([
             ("ts", `String (Masc_domain.iso8601_of_unix_seconds now));
             ("ts_unix", `Float now);
             ("channel", `String "tool_event");
             ("metric_event", `String "keeper_pr_review_action");
             ("name", `String meta.name);
             ("agent_name", `String meta.agent_name);
             ( "trace_id",
               `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id) );
             ("generation", `Int generation);
             ("tool_name", `String tool_name);
             ("pr_review_action", `String event.action);
             ("pr_review_action_success", `Bool event.success);
             ("tool_call_count", `Int 0);
             ("tools_used", `List []);
             ("pr_number", Json_util.int_opt_to_json event.pr_number);
             ("comment_id", Json_util.int_opt_to_json event.comment_id);
             ("duration_ms", `Float duration_ms);
           ]
           @ route_fields
           @ identity_fields)
      in
      Dated_jsonl.append store (Inference_utils.sanitize_json_utf8 snapshot)

let append_pr_work_action_metrics
    ~(config : Coord.config)
    ~(meta : Keeper_types.keeper_meta)
    ~(generation : int)
    ~(tool_name : string)
    ~(input : Yojson.Safe.t)
    ~(output_text : string)
    ~(transport_success : bool)
    ~(duration_ms : float)
    () =
  let route_via_fallback =
    match meta.sandbox_profile, tool_name with
    | Docker, "keeper_pr_create" ->
        if Env_config_keeper.KeeperSandbox.hard_mode () then Some "brokered"
        else Some "docker"
    | Docker, "keeper_shell" ->
        if Env_config_keeper.KeeperSandbox.hard_mode () then Some "brokered"
        else Some "docker"
    | Docker, ("keeper_bash" | "masc_code_shell" | "masc_code_git") ->
        Some "docker"
    | _ -> None
  in
  let events =
    pr_work_action_metric_events_of_tool_io
      ~route_via_fallback ~tool_name ~input ~output_text ~transport_success
  in
  match events with
  | [] -> ()
  | _ ->
      let store = Keeper_types.keeper_pr_action_metrics_store config meta.name in
      List.iter
        (fun event ->
           let now = Time_compat.now () in
           let route_fields =
             match event.route_via with
             | None -> []
             | Some via -> [("via", `String via); ("route_via", `String via)]
           in
           let snapshot =
             `Assoc
               ([
                  ("ts", `String (Masc_domain.iso8601_of_unix_seconds now));
                  ("ts_unix", `Float now);
                  ("channel", `String "tool_event");
                  ("metric_event", `String "keeper_pr_work_action");
                  ("name", `String meta.name);
                  ("agent_name", `String meta.agent_name);
                  ( "trace_id",
                    `String
                      (Keeper_id.Trace_id.to_string meta.runtime.trace_id) );
                  ("generation", `Int generation);
                  ("tool_name", `String tool_name);
                  ("pr_work_action", `String event.work_action);
                  ("pr_work_action_source", `String event.work_source);
                  ("pr_work_action_success", `Bool event.success);
                  ( "pr_work_ref",
                    Json_util.string_opt_to_json event.work_ref );
                  ("pr_url", Json_util.string_opt_to_json event.pr_url);
                  ( "pr_work_command",
                    Json_util.string_opt_to_json event.command );
                  ("tool_call_count", `Int 0);
                  ("tools_used", `List []);
                  ("duration_ms", `Float duration_ms);
                ]
                @ route_fields)
           in
           Dated_jsonl.append store
             (Inference_utils.sanitize_json_utf8 snapshot))
        events

let make_hooks
    ~(config : Coord.config)
    ~(meta_ref : Keeper_types.keeper_meta ref)
    ~(generation : int)
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ?(pre_tool_use_guard :
        tool_name:string -> input:Yojson.Safe.t -> string option =
        fun ~tool_name:_ ~input:_ -> None)
    ?(on_tool_executed :
        tool_name:string -> input:Yojson.Safe.t -> output_text:string ->
        success:bool -> duration_ms:float -> provider:string -> unit =
        fun ~tool_name:_ ~input:_ ~output_text:_ ~success:_ ~duration_ms:_ ~provider:_ -> ())
    ?(trajectory_acc : Trajectory.accumulator option)
    ?(discover_work_nudge : unit -> string option =
        fun () -> None)
    ?(passive_loop_nudge : unit -> string option =
        fun () -> None)
    ()
  : Agent_sdk.Hooks.hooks =
  let sse_turn_complete = "keeper_turn_complete" in
  let tool_start_time = ref 0.0 in
  (* Per-turn tool call counter for SSE enrichment.
     Incremented in post_tool_use, reset in after_turn. *)
  let tool_call_count_ref = ref 0 in
  (* Streak gate state: tracks consecutive calls to the same tool
     name (regardless of args). Lives across invocations via the
     [make_hooks] closure — one state per keeper. *)
  let streak_state = Keeper_guards.make_streak_state () in
  let streak_threshold = 5 in
  let record_gate_decision event =
    record_pre_tool_gate_attempt
      ~meta_ref
      ~tool_call_count_ref
      ?trajectory_acc
      event
  in
  (* Build the pre_tool_use guard chain via Hooks.compose. Each guard
     lives in Keeper_guards and emits its own masc:keeper_gate event
     on override/approval decisions. The observer persists the same
     attempted action into tool-call and trajectory lanes so blocked
     pre-tool attempts are not invisible to tool-stats. *)
  let guard_chain =
    Keeper_guards.build_chain
      ~meta_ref
      ~tool_start_time
      ~streak_state
      ~streak_threshold
      ~denied:keeper_denied_tools
      ~max_cost_usd
      ~destructive_check
      ~on_gate_decision:record_gate_decision
      ~pre_tool_use_guard
  in
  let non_gate_hooks =
    { Agent_sdk.Hooks.empty with

    (* Work discovery injection (#8773 fix) and passive loop action injection
       (#12799 P1/5). The callbacks own their policy and return Some text only
       when there is actionable content to surface. The passive loop nudge
       takes priority (prepended) when active, since it requires immediate
       action. Hook stays domain-agnostic: it wraps payloads in a Nudge so
       the next LLM turn sees them as ambient observation. Returns Continue
       when both callbacks yield None — silent no-op, no token cost. *)
    before_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.BeforeTurn _ ->
        let loop_alert = passive_loop_nudge () in
        let work_text = discover_work_nudge () in
        let combined_with_source =
          match loop_alert, work_text with
          | None, None -> None
          | Some a, None -> Some (a, "passive_loop_nudge")
          | None, Some w -> Some (w, "work_discovery")
          | Some a, Some w ->
            Some (a ^ "\n\n" ^ w, "passive_loop_nudge + work_discovery")
        in
        (match combined_with_source with
         | None -> Agent_sdk.Hooks.Continue
         | Some (text, _) when String.trim text = "" ->
           Agent_sdk.Hooks.Continue
         | Some (text, _) when not (String.is_valid_utf_8 text) ->
           (* Defensive: nudge path producers source strings from external
              input (task titles, operator guidance, board posts). A byte-
              level truncation upstream can leave an orphan UTF-8 continuation
              byte, and codex CLI rejects the resulting argv with "invalid
              UTF-8 was detected in one or more arguments" at parse time
              (non-cascadable). This gate prevents polluted nudges from ever
              reaching transport argv, regardless of which producer introduced
              the drift. See #9036 for the first observed producer fix. *)
           Log.Keeper.warn "keeper:%s before_turn: dropped invalid UTF-8 nudge (%d bytes)"
             (!meta_ref).name (String.length text);
           Agent_sdk.Hooks.Continue
         | Some (text, source) ->
           Log.Keeper.info "keeper:%s before_turn: injecting %s (%d chars)"
             (!meta_ref).name source (String.length text);
           Agent_sdk.Hooks.Nudge text)
      | _ -> Agent_sdk.Hooks.Continue);

    after_turn = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.AfterTurn { turn; response } ->
        let meta = !meta_ref in
        let model = resolve_after_turn_model ~keeper_name:meta.name ~response in
        let usage_trust =
          classify_usage_trust ?usage:response.usage ~model
            ~telemetry:response.telemetry ()
        in
        let usage_trusted = Keeper_usage_trust.is_trusted usage_trust in
        record_usage_anomaly_metrics ~keeper_name:meta.name ~model usage_trust;
        let raw_input_tok, raw_output_tok =
          match response.usage with
          | Some u -> u.input_tokens, u.output_tokens
          | None -> 0, 0
        in
        let input_tok, output_tok, turn_cost_usd, usage_missing =
          match response.usage with
          | Some u when usage_trusted ->
              let provider_kind = provider_kind_of_telemetry response.telemetry in
              ( u.input_tokens,
                u.output_tokens,
                cost_usd_for_usage ?provider_kind ~model u,
                false )
          | Some _ -> (0, 0, 0.0, false)
          | None -> (0, 0, 0.0, true)
        in
        let cost_usd_for_event =
          if usage_trusted then turn_cost_usd
          else
            match response.usage with
            | Some { cost_usd = Some cost; _ } when cost > 0.0 -> cost
            | Some _ | None -> 0.0
        in
        let total_tok = input_tok + output_tok in
        if (not usage_missing) && not usage_trusted then
          Log.Keeper.warn
            "keeper:%s after_turn usage telemetry untrusted model=%s resolved_model=%s reasons=%s input=%d output=%d context_max=%d"
            meta.name model
            (canonical_model_id_of_telemetry ~model response.telemetry)
            (String.concat ","
               (match Keeper_usage_trust.reasons usage_trust with
                | [] -> [Keeper_usage_trust.to_string usage_trust]
                | reasons -> reasons))
            raw_input_tok raw_output_tok
            (context_max_of_telemetry response.telemetry);
        (* Provider prefix cache token tracking (Anthropic).
           Non-Anthropic providers report 0 for these fields. *)
        (match response.usage with
         | Some u when usage_trusted ->
           let cc = u.cache_creation_input_tokens in
           let cr = u.cache_read_input_tokens in
           if cc > 0 then
             Prometheus.inc_counter
               Prometheus.metric_provider_prefix_cache_creation_tokens
               ~delta:(Float.of_int cc) ();
           if cr > 0 then
             Prometheus.inc_counter
               Prometheus.metric_provider_prefix_cache_read_tokens
               ~delta:(Float.of_int cr) ()
         | Some _ | None -> ());
        (* Inference latency histogram for /metrics endpoint.
           Missing telemetry stays a separate counter; zero/negative latency
           increments the zero-latency counter and observes a 1ms floor so the
           histogram still proves the hook ran. *)
        record_llm_inference_latency_metric ~model
          ~telemetry:response.telemetry;
        let fmt_tok_s = function
          | Some v -> Printf.sprintf "%.1f" v
          | None -> "-"
        in
        (* Capture each telemetry projection independently.  Anthropic and
           Gemini populate [request_latency_ms] (patched in OAS api.ml) but
           leave [timings = None]; the previous single-match folded those
           three fields together and surfaced [latency_ms=0] whenever tok/s
           were missing, which hid Anthropic/Gemini latency on the log line
           and in downstream dashboards. *)
        let prompt_tok_s_opt, decode_tok_s_opt =
          match response.telemetry with
          | Some { timings = Some t; _ } ->
              t.prompt_per_second, t.predicted_per_second
          | _ -> None, None
        in
        let latency_ms =
          match response.telemetry with
          | Some t -> Option.value ~default:0 t.request_latency_ms
          | None -> 0
        in
        let wall_tok_s_opt =
          if usage_trusted then
            wall_tokens_per_second ~usage_missing ~output_tokens:output_tok
              ~telemetry:response.telemetry
          else None
        in
        record_llm_tok_s_metrics ~model ~telemetry:response.telemetry;
        let wall_tok_s = fmt_tok_s wall_tok_s_opt in
        let prompt_tok_s = fmt_tok_s prompt_tok_s_opt in
        let decode_tok_s = fmt_tok_s decode_tok_s_opt in
        Log.Keeper.info
          "keeper:%s turn=%d total_turns=%d model=%s tokens=%d wall_tok_s=%s prompt_tok_s=%s decode_tok_s=%s latency_ms=%d"
          meta.name turn meta.runtime.usage.total_turns model total_tok
          wall_tok_s prompt_tok_s decode_tok_s latency_ms;
        (* Emit per-turn cost event for task attribution.
           cost_usd from OAS Pricing.annotate_response_cost (oas#393 resolved). *)
        (match trajectory_acc with
         | Some acc ->
           emit_cost_event ~masc_root:acc.masc_root
             ~agent_name:meta.name ~task_id:acc.task_id
             ~model ~input_tokens:raw_input_tok ~output_tokens:raw_output_tok
             ~cost_usd:cost_usd_for_event ~usage_missing
             ~usage_trust
             ?telemetry:response.telemetry ()
         | None -> ());
        let text = Agent_sdk.Types.text_of_content response.content in
        let has_state_block =
          Option.is_some (Keeper_memory_policy.find_state_block text)
        in
        if not has_state_block && turn > 0 then
          Log.Keeper.debug
            "keeper:%s turn=%d state_block=absent (awaiting post-run synthesis)"
            meta.name turn;
        (try
           Sse.broadcast
             (`Assoc
               [
                 ("type", `String sse_turn_complete);
                 ("name", `String meta.name);
                 ("generation", `Int generation);
                 ("turn", `Int turn);
                 ("model_used", `String model);
                 ("input_tokens", `Int input_tok);
                 ("output_tokens", `Int output_tok);
                 ("has_state_block", `Bool has_state_block);
                 ("cost_usd", `Float turn_cost_usd);
                 ("tool_calls_made", `Int !tool_call_count_ref);
                 ("total_turns", `Int meta.runtime.usage.total_turns);
                 ("ts_unix", `Float (Unix.gettimeofday ()));
               ])
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             (* P2 silent-failure fix: turn-complete event was previously
                dropped without trace.  Dashboard's per-turn marker would
                go missing intermittently and operators had no signal that
                the broadcast itself failed.  PR-C (#11075) added a
                broadcast-failures counter on the SSE side, but it only
                catches per-client failures inside broadcast_impl —
                exceptions thrown from Sse.broadcast at the call boundary
                bypass that counter.  Logging here makes the loss visible
                at the producer site. *)
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:[("keeper", meta.name); ("callback", "after_turn_sse_broadcast")]
               ();
             Log.Keeper.warn
               "keeper:%s turn=%d sse_turn_complete broadcast failed: %s"
               meta.name turn (Printexc.to_string exn));
        (* Reset same-name streak at turn boundary so it doesn't
           carry across turns (e.g., 4 calls in turn N + 1 in turn N+1
           should not hit threshold 5). *)
        streak_state.Keeper_guards.entry <- ("", 0);
        tool_call_count_ref := 0;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    post_tool_use = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.PostToolUse { tool_name; input; output; duration_ms = hook_duration_ms; _ } ->
        incr tool_call_count_ref;
        let output_text = match output with
          | Ok { Agent_sdk.Types.content; _ } -> content
          | Error { Agent_sdk.Types.message; _ } -> message
        in
        let input_keys = match input with
          | `Assoc pairs -> String.concat "," (List.map fst pairs)
          | _ -> "-"
        in
        let outcome, out_len = match output with
          | Ok { Agent_sdk.Types.content; _ } -> "ok", String.length content
          | Error { Agent_sdk.Types.message; _ } -> "error", String.length message
        in
        Log.Keeper.info "keeper:%s tool_call tool=%s params=[%s] outcome=%s out_len=%d"
          (!meta_ref).name tool_name input_keys outcome out_len;
        (* Persistent tool call I/O log for dashboard inspector.
           tool_start_time is keeper-local (one ref per make_hooks call).
           Tool calls within Agent.run are sequential, so no race. *)
        let duration_ms =
          if hook_duration_ms > 0.0
          then hook_duration_ms
          else (Time_compat.now () -. !tool_start_time) *. 1000.0
        in
        let model =
          let m = (!meta_ref).runtime.usage.last_model_used in
          if m = "" then (Keeper_types.cascade_name_of_meta !meta_ref) else m
        in
        let summary =
          tool_execution_summary
            ~tool_name
            ~model
            ~success:(outcome = "ok")
            ~duration_ms
        in
        record_keeper_tool_duration_metric
          ~keeper_name:(!meta_ref).name
          summary;
        (* Consume truncation info set by keeper_tools_oas before returning
           the (possibly truncated) result to OAS. Falls back to out_len
           when no truncation info was set (e.g. OAS-internal tool calls). *)
        let (original_bytes, truncated_to) =
          Keeper_tool_call_log.consume_truncation_info
            ~keeper_name:(!meta_ref).name ()
        in
        let result_bytes = if original_bytes > 0 then original_bytes else out_len in
        let handler_logged =
          Keeper_tool_call_log.consume_handler_logged
            ~keeper_name:(!meta_ref).name
            ~tool_name
            ~output_text
            ~success:(outcome = "ok")
            ()
        in
        let ( lane
            , tool_choice
            , thinking_enabled
            , thinking_budget
            , prompt_fingerprint
            , trace_id
            , session_id
            , turn
            , keeper_turn_id
            , task_id
            , goal_ids
            , sandbox_profile
            , network_mode
            , approval_mode ) =
          Keeper_tool_call_log.get_turn_context
            ~keeper_name:(!meta_ref).name ()
        in
        if not handler_logged then
          (try
             Keeper_tool_call_log.log_call
               ~keeper_name:(!meta_ref).name
               ~tool_name ~input ~output_text
               ~success:(outcome = "ok") ~duration_ms
               ~model:(let m = (!meta_ref).runtime.usage.last_model_used in
                       if m = "" then (Keeper_types.cascade_name_of_meta !meta_ref) else m)
               ?lane ?tool_choice ?thinking_enabled ?thinking_budget
               ?prompt_fingerprint
               ?trace_id ?session_id ?turn ?keeper_turn_id ?task_id ?goal_ids
               ?sandbox_profile ?network_mode ?approval_mode
               ~result_bytes ?truncated_to ()
           with
           | Eio.Cancel.Cancelled _ as e -> raise e
           | exn ->
               (* P2 silent-failure fix (same pattern as the broadcast site
                  above at line ~1098): tool-call audit log write failures
                  were dropped without trace.  Loss of these rows leaves
                  downstream replay / debugging tools with gaps that look
                  identical to "no tool calls in this turn." *)
               Prometheus.inc_counter
                 Keeper_metrics.metric_keeper_lifecycle_callback_failures
                 ~labels:[("keeper", (!meta_ref).name); ("callback", "post_tool_log_write")]
                 ();
               Log.Keeper.warn
                 "keeper:%s tool=%s log_call write failed: %s"
                 (!meta_ref).name tool_name (Printexc.to_string exn));
        (try
           append_pr_review_action_metric
             ~config
             ~meta:(!meta_ref)
             ~generation
             ~tool_name
             ~input
             ~output_text
             ~transport_success:(outcome = "ok")
             ~duration_ms
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:
                 [
                   ("keeper", (!meta_ref).name);
                   ("callback", "pr_review_action_metrics_append");
                 ]
               ();
             Log.Keeper.warn
               "keeper:%s tool=%s pr_review_action metric append failed: %s"
               (!meta_ref).name tool_name (Printexc.to_string exn));
        (try
           append_pr_work_action_metrics
             ~config
             ~meta:(!meta_ref)
             ~generation
             ~tool_name
             ~input
             ~output_text
             ~transport_success:(outcome = "ok")
             ~duration_ms
             ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
             Prometheus.inc_counter
               Keeper_metrics.metric_keeper_lifecycle_callback_failures
               ~labels:
                 [
                   ("keeper", (!meta_ref).name);
                   ("callback", "pr_work_action_metrics_append");
                 ]
               ();
             Log.Keeper.warn
               "keeper:%s tool=%s pr_work_action metric append failed: %s"
               (!meta_ref).name tool_name (Printexc.to_string exn));
        (match trajectory_acc with
         | None -> ()
         | Some acc ->
           let keeper_name = (!meta_ref).name in
           let trace_id = acc.Trajectory.trace_id in
           let safe_input =
             Observability_redact.redact_json_value input
           in
           let safe_output =
             Observability_redact.redact_preview
               ~max_len:4000
               output_text
           in
           let runtime_contract =
             Keeper_tool_call_log.runtime_contract_json_for_call
               ~keeper_name
               ~model
               ()
           in
           let action_radius =
             Keeper_tool_call_log.action_radius_json_for_call
               ~keeper_name
               ~tool_name
               ~input:safe_input
               ~success:(outcome = "ok")
               ~duration_ms
               ?error:(if outcome = "ok" then None else Some safe_output)
               ()
           in
           let now = Time_compat.now () in
           let entry : Trajectory.tool_call_entry =
             {
               ts = now;
               ts_iso = Masc_domain.iso8601_of_unix_seconds now;
               turn = acc.Trajectory.turn;
               round = Trajectory.calls_in_current_turn acc + 1;
               tool_name;
               args_json = Yojson.Safe.to_string safe_input;
               gate_decision = Trajectory.Pass;
               result = Some safe_output;
               duration_ms = trajectory_duration_ms duration_ms;
               error = (if outcome = "ok" then None else Some safe_output);
               cost_usd = Trajectory.tool_cost_estimate tool_name;
             }
           in
           Trajectory.record_entry
             ~runtime_contract
             ~action_radius
             ~on_persist_error:(fun exn ->
               Telemetry_coverage_gap.record
                 ~masc_root:acc.Trajectory.masc_root
                 ~source:"trajectory_tool_call"
                 ~producer:"keeper_hooks_oas.post_tool_use"
                 ~durable_store:
                   (Trajectory.trajectory_path acc.Trajectory.masc_root
                      acc.Trajectory.keeper_name trace_id)
                 ~dashboard_surface:"/api/v1/keepers/:name/tool-stats"
                 ~stale_reason:"trajectory_append_failed"
                 ~keeper_name
                 ~trace_id
                 ~error:(Printexc.to_string exn)
                 ())
             acc
             entry);
        (try
           on_tool_executed
             ~tool_name
             ~input
             ~output_text
             ~success:(outcome = "ok")
             ~duration_ms:summary.duration_ms
             ~provider:summary.provider
         with Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Prometheus.inc_counter
                Keeper_metrics.metric_keeper_lifecycle_callback_failures
                ~labels:[("keeper", (!meta_ref).name); ("callback", "on_tool_executed")]
                ();
              Log.Keeper.error "keeper:%s on_tool_executed callback failed for %s: %s"
                (!meta_ref).name tool_name (Printexc.to_string exn));
        if is_keeper_board_write_tool_name tool_name then
          Log.Keeper.debug "keeper:%s social_event tool=%s"
            (!meta_ref).name tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    (* pre_tool_use is provided by [guard_chain] below via Hooks.compose.
       The guard chain (timing + custom + streak + deny + cost +
       destructive + governance_approval) is composed with these
       non-gate hooks at the end of [make_hooks]. *)

    on_stop = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnStop { reason; _ } ->
        Prometheus.inc_counter Keeper_metrics.metric_keeper_oas_on_stop
          ~labels:
            [
              ("keeper", (!meta_ref).name);
              ("stop_reason", stop_reason_to_label reason);
            ]
          ();
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdle { consecutive_idle_turns; tool_names; _ } ->
        keeper_idle_decision ~meta_ref ~consecutive_idle_turns ~tool_names
      | _ -> Agent_sdk.Hooks.Continue);

    on_idle_escalated = Some (fun event ->
      match event with
      | Agent_sdk.Hooks.OnIdleEscalated
          { severity; consecutive_idle_turns; tool_names; _ } ->
        let decision =
          keeper_idle_decision ~meta_ref ~consecutive_idle_turns ~tool_names in
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_oas_on_idle_escalated
          ~labels:
            [
              ("keeper", (!meta_ref).name);
              ("severity", idle_severity_to_label severity);
              ("decision", idle_decision_to_label decision);
            ]
          ();
        decision
      | _ -> Agent_sdk.Hooks.Continue);

    on_error = Some (function
      | Agent_sdk.Hooks.OnError { detail; context = err_ctx } ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_lifecycle_callback_failures
          ~labels:[("keeper", (!meta_ref).name); ("callback", "on_error")]
          ();
        Log.Keeper.error "keeper:%s on_error: %s (context: %s)"
          (!meta_ref).name detail err_ctx;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    on_tool_error = Some (function
      | Agent_sdk.Hooks.OnToolError { tool_name; error } ->
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_lifecycle_callback_failures
          ~labels:[("keeper", (!meta_ref).name); ("callback", "on_tool_error")]
          ();
        Log.Keeper.error "keeper:%s tool_error: %s — %s"
          (!meta_ref).name tool_name error;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);

    post_tool_use_failure = Some (function
      | Agent_sdk.Hooks.PostToolUseFailure { tool_name; error; _ } ->
        let meta = !meta_ref in
        (* The richer counterpart
             "tool <name> returned error result (n/max): <detail>"
           is already emitted at ERROR by keeper_tools_oas before this
           hook runs. Emitting a second ERROR here with the same error
           content produces paired duplicate lines per tool failure —
           keep a debug trace for hook-chain readers only. *)
        Log.Keeper.debug "keeper:%s tool_use_failure: %s — %s"
          meta.name tool_name error;
        (* #9919: this path is a count event, not a heuristic decision. *)
        record_tool_use_failure ~keeper_name:meta.name ~tool_name;
        Agent_sdk.Hooks.Continue
      | _ -> Agent_sdk.Hooks.Continue);
  }
  in
  (* Guards fire first (outer). If all return Continue, non_gate_hooks
     fire for the remaining slots (inner). pre_tool_use lives in
     guard_chain only; non_gate_hooks has it None, so Hooks.compose
     keeps guard_chain's pre_tool_use verbatim. *)
  Agent_sdk.Hooks.compose ~outer:guard_chain ~inner:non_gate_hooks

module For_testing = struct
  let pr_review_action_metric_event_of_tool_io =
    pr_review_action_metric_event_of_tool_io

  let pr_work_action_metric_events_of_tool_io =
    pr_work_action_metric_events_of_tool_io
end

(** Static introspection of hook slot configuration.
    Returns a JSON summary of which hook slots are active, their gates/effects,
    and the deny list. Used by the dashboard to display hook status. *)
let hook_slot_json ?(features = []) ?(gates = []) ?(effects = [])
    ?reason ~(active : bool) ~(source : string) () : Yojson.Safe.t =
  let list_field name values =
    match values with
    | [] -> []
    | xs -> [ (name, `List (List.map (fun s -> `String s) xs)) ]
  in
  `Assoc
    ([
       ("active", `Bool active);
       ("source", `String source);
     ]
     @ (match reason with
       | None -> []
       | Some value -> [ ("reason", `String value) ])
     @ list_field "features" features
     @ list_field "gates" gates
     @ list_field "effects" effects)

let hook_introspection_json
    ?(max_cost_usd : float option)
    ?(destructive_check : bool = true)
    ()
  : Yojson.Safe.t =
  let denied_json =
    `List (List.map (fun s -> `String s) keeper_denied_tools)
  in
  let destructive_json =
    `String "dynamic_boundary (Tool_dispatch.is_destructive)"
  in
  (* Build (name, active, json) triples in one place so the active
     flag is captured at construction time rather than recovered by
     re-inspecting the just-built JSON later. *)
  let slot ?features ?gates ?effects ?reason ~active ~source name =
    let features = Option.value features ~default:[] in
    let gates = Option.value gates ~default:[] in
    let effects = Option.value effects ~default:[] in
    let json =
      hook_slot_json ~features ~gates ~effects ?reason ~active ~source ()
    in
    (name, active, json)
  in
  let slot_entries =
    [
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:
          [
            "work_discovery_nudge";
            "passive_loop_nudge";
            "utf8_guard";
          ]
        "before_turn";
      slot
        ~active:true
        ~source:"keeper_run_tools"
        ~features:
          [
            "dynamic_context";
            "adaptive_thinking_budget";
            "tool_surface_selection";
            "memory_injection";
          ]
        "before_turn_params";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:
          [
            "sse_broadcast";
            "cost_event";
            "metrics";
            "usage_trust";
            "tool_streak_reset";
          ]
        "after_turn";
      slot
        ~active:true
        ~source:"keeper_guards"
        ~gates:
          [
            "timing";
            "custom_guard";
            "streak_gate";
            "keeper_deny_list";
            (if Option.is_some max_cost_usd
             then "cost_budget"
             else "cost_budget_off");
            (if destructive_check
             then "destructive_pattern"
             else "destructive_pattern_off");
            "governance_approval";
          ]
        "pre_tool_use";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:
          [
            "tool_callback";
            "tool_call_log";
            "trajectory";
            "board_write_detection";
            "tool_emission_capture";
          ]
        "post_tool_use";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "tool_use_failure_metric" ]
        "post_tool_use_failure";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "stop_reason_metric" ]
        "on_stop";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~features:[ "repeated_tool_nudge"; "stay_silent_skip" ]
        "on_idle";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "idle_escalation_metric" ]
        "on_idle_escalated";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "wirein_failure_metric"; "keeper_error_log" ]
        "on_error";
      slot
        ~active:true
        ~source:"keeper_hooks_oas"
        ~effects:[ "wirein_failure_metric"; "keeper_error_log" ]
        "on_tool_error";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "pre_compact";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "post_compact";
      slot
        ~active:false
        ~source:"not_registered"
        ~reason:"compaction is handled by keeper_post_turn"
        "on_context_compacted";
    ]
  in
  (* Reviewer #13225: counts used to be derived by re-parsing the
     just-built JSON [Assoc] for an "active" field.  If
     [hook_slot_json]'s shape ever drifts (extra wrapper, renamed
     field) the counts would silently desync from reality.  Track
     [active] alongside each slot at build time so the counts are
     decided where the slot is constructed, not by inspecting JSON. *)
  let active_count =
    List.fold_left
      (fun acc (_name, active, _json) -> if active then acc + 1 else acc)
      0 slot_entries
  in
  let total_count = List.length slot_entries in
  let inactive_count = total_count - active_count in
  let slot_names =
    `List (List.map (fun (name, _, _) -> `String name) slot_entries)
  in
  let slot_assoc =
    List.map (fun (name, _active, json) -> (name, json)) slot_entries
  in
  `Assoc [
    ("scope", `String "keeper_runtime_composite");
    ("slots", `Assoc slot_assoc);
    ("slot_names", slot_names);
    ("slot_count", `Int total_count);
    ("active_slot_count", `Int active_count);
    ("inactive_slot_count", `Int inactive_count);
    ("deny_list", denied_json);
    ("deny_list_count", `Int (List.length keeper_denied_tools));
    ("destructive_check_tools", destructive_json);
    ("cost_budget",
      match max_cost_usd with
      | Some v ->
        `Assoc [("max_cost_usd", `Float v); ("active", `Bool true)]
      | None ->
        `Assoc [("active", `Bool false)]);
  ]
