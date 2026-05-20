(** Keeper_compact_policy — compaction gate and strategy application.

    Decides whether compaction should run based on ratio/message/token
    gates and cooldown, then applies OAS strategies + persona fold.

    Extracted from Keeper_exec_context as part of #4955 god-file split. *)

open Keeper_types
open Keeper_context_core

(** Fraction of context window at which compaction is treated as an
    emergency, bypassing the continuity-reflection cooldown gate.
    Distinct from [ratio_gate] (per-keeper compaction threshold) and
    [handoff_threshold] (handoff gate); this is a safety floor that
    prevents context overflow regardless of cooldown state (#5634).

    Operator override: [MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD].
    Default 0.8. Valid range [0.5, 0.99]; out-of-range falls back to
    the default with a one-time warn (parse-correctness, not silent
    coercion — a stale operator typo should not push the emergency
    floor outside the policy envelope, but it also should not block
    boot). The effective value is exposed via Prometheus gauge
    {!Keeper_metrics.metric_keeper_emergency_compact_ratio_threshold}
    so operators can see what the running process is actually using.

    Read once at module init: keeper compact policy is a hot path and
    re-reading env per gate call would be wasteful. Operator must
    restart the process to change the threshold (consistent with
    [context_ratio_hard_cap] and other compact knobs in
    {!Env_config_keeper}). *)
let emergency_compact_ratio_threshold : float =
  let env_var = "MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD" in
  let default_value = 0.8 in
  let min_valid = 0.5 in
  let max_valid = 0.99 in
  (* Read raw env directly (not Env_config_core.get_float ~default) so we can
     distinguish three observable cases:
       1. env unset           → silent default
       2. env set & parses    → validate range; warn on out-of-range
       3. env set & malformed → warn explicitly with distinct message
     get_float ~default collapses (1) and (3) into the same float value,
     making operator typos (e.g. "foo" or "0,9" with comma) indistinguishable
     from the unset case. The subsequent Float.equal raw default_value check
     then suppresses the warn path entirely. (Codex P2 review of PR #15782.) *)
  let effective =
    match Sys.getenv_opt env_var with
    | None -> default_value
    | Some raw ->
      (match Float.of_string_opt (String.trim raw) with
       | None ->
         Log.Harness.warn
           "[compact_policy] %s=%S is not a parseable float; falling back to default \
            %.2f"
           env_var
           raw
           default_value;
         default_value
       | Some parsed when not (Float.is_finite parsed) ->
         Log.Harness.warn
           "[compact_policy] %s=%s parsed to non-finite %f; falling back to default %.2f"
           env_var
           raw
           parsed
           default_value;
         default_value
       | Some parsed when parsed < min_valid || parsed > max_valid ->
         Log.Harness.warn
           "[compact_policy] %s=%f out of range [%.2f, %.2f]; falling back to default \
            %.2f"
           env_var
           parsed
           min_valid
           max_valid
           default_value;
         default_value
       | Some parsed -> parsed)
  in
  (* Surface the effective value for operators via /metrics. Registered
     here so the gauge exists from module init regardless of whether any
     compaction has fired yet. *)
  Prometheus.register_gauge
    ~name:Keeper_metrics.metric_keeper_emergency_compact_ratio_threshold
    ~help:
      "Effective emergency compaction ratio threshold (env-overridable via \
       MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD; clamped to [0.5, 0.99])."
    ();
  Prometheus.set_gauge
    Keeper_metrics.metric_keeper_emergency_compact_ratio_threshold
    effective;
  effective
;;

(** Tool-heavy compaction thresholds.
    When message count exceeds [tool_heavy_msg_threshold] AND context
    ratio exceeds [tool_heavy_ratio_floor], trigger compaction to
    stub old tool results. Prevents slow inference on local LLMs
    when many tool calls accumulate without hitting other gates. *)
let tool_heavy_msg_threshold = 40

let tool_heavy_ratio_floor = 0.15

type compaction_decision =
  | Applied of Compaction_trigger.t
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_continuity_reflection of
      { hold_s : float
      ; cooldown_sec : int
      }

let compaction_decision_to_string = function
  | Applied trigger -> "applied:" ^ Compaction_trigger.to_human trigger
  | Blocked_below_thresholds -> "blocked:below_thresholds"
  | Skipped_no_checkpoint -> "skipped:no_checkpoint"
  | Skipped_continuity_reflection { hold_s; cooldown_sec } ->
    Printf.sprintf "skipped:continuity_reflection(%0.0fs<%ds)" hold_s cooldown_sec
;;

let compaction_decision_applied = function
  | Applied _ -> true
  | Blocked_below_thresholds | Skipped_no_checkpoint | Skipped_continuity_reflection _ ->
    false
;;

let decide_compaction
      ~ratio
      ~msg_count
      ~tok_count
      ~ratio_gate
      ~message_gate
      ~token_gate
      ~cooldown_sec
      ~last_continuity_update_ts
      ~last_proactive_ts
      ~now_ts
  =
  let cooldown = Float.of_int cooldown_sec in
  let last_reflection_ts =
    max last_continuity_update_ts last_proactive_ts
  in
  let emergency = ratio >= emergency_compact_ratio_threshold in
  let reflection_ready =
    emergency
    || last_reflection_ts <= 0.0
    || (last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown)
  in
  let hold_s =
    if cooldown <= 0.0 || emergency || last_reflection_ts <= 0.0
    then 0.0
    else max 0.0 (Float.of_int cooldown_sec -. (now_ts -. last_reflection_ts))
  in
  (* Tool-heavy compaction is an operational safety valve: accumulated
     tool result bloat slows local inference and can hide below the
     normal ratio/message/token gates, so it bypasses the reflection
     cooldown like the emergency ratio gate. *)
  let tool_heavy =
    msg_count > tool_heavy_msg_threshold
    && ratio > tool_heavy_ratio_floor
  in
  if not reflection_ready && not tool_heavy
  then Skipped_continuity_reflection { hold_s; cooldown_sec }
  else if ratio >= ratio_gate
  then Applied (Compaction_trigger.Ratio_threshold { ratio; threshold = ratio_gate })
  else if message_gate > 0 && msg_count >= message_gate
  then Applied (Compaction_trigger.Message_count { count = msg_count; threshold = message_gate })
  else if token_gate > 0 && tok_count >= token_gate
  then Applied (Compaction_trigger.Token_count { count = tok_count; threshold = token_gate })
  else if tool_heavy
  then Applied (Compaction_trigger.Tool_heavy { messages = msg_count; ratio })
  else Blocked_below_thresholds
;;

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  meta.compaction.ratio_gate, meta.compaction.message_gate, meta.compaction.token_gate
;;

let compact_if_needed_typed
      ~(meta : keeper_meta)
      ~(now_ts : float)
      (ctx : working_context)
  : working_context * Compaction_trigger.t option * compaction_decision
  =
  let ratio = context_ratio ctx in
  let msg_count = message_count ctx in
  (* NOTE(boundary): tok_count is raw infrastructure — ideally ratio alone
     suffices.  token_gate is kept for backward compat; most profiles
     default token_gate=0 which disables this gate.  See keeper_guard.ml. *)
  let tok_count = token_count ctx in
  let ratio_gate, message_gate, token_gate = compaction_policy_of_keeper meta in
  let decision =
    decide_compaction
      ~ratio
      ~msg_count
      ~tok_count
      ~ratio_gate
      ~message_gate
      ~token_gate
      ~cooldown_sec:meta.compaction.cooldown_sec
      ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
      ~last_proactive_ts:meta.runtime.proactive_rt.last_ts
      ~now_ts
  in
  match decision with
  | Blocked_below_thresholds | Skipped_no_checkpoint | Skipped_continuity_reflection _ ->
    ctx, None, decision
  | Applied trigger ->
    (* PreCompact observability: log strategy and context state (#3165) *)
    let strategies =
      Context_compact_oas.[ PruneToolOutputs; MergeContiguous; DropLowImportance ]
    in
    (* Use OAS stub_tool_results instead of MASC's FoldCompleted —
         OAS owns context reduction, MASC is a consumer. *)
    (* V12: per-keeper config replaces the prior hardcoded
         [~keep_recent:2].  Default preserved via
         [Keeper_config.default_keep_recent_tool_results] = 2 so
         existing configs see no behavior change. *)
    let fold_reducer =
      Agent_sdk.Context_reducer.stub_tool_results
        ~keep_recent:meta.compaction.keep_recent_tool_results
    in
    let strategy_names =
      List.map Context_compact_oas.strategy_name strategies @ [ "StubToolResults" ]
    in
    let trigger_human = Compaction_trigger.to_human trigger in
    let trigger_label = Compaction_trigger.to_label trigger in
    let trigger_detail = Compaction_trigger.to_detail_json trigger in
    Log.Harness.info
      "[pre_compact] keeper=%s ratio=%.4f messages=%d tokens=%d trigger=%s"
      meta.name
      ratio
      msg_count
      tok_count
      trigger_human;
    let model_meta =
      let model_labels = Keeper_model_labels.configured_model_labels_of_meta meta in
      Cascade_runtime_candidate.context_window_hint_of_labels model_labels
    in
    (* record_pre_compact's JSONL append is wrapped by
       append_store_json_fail_open in Dashboard_harness_health, so this call
       does not propagate non-Cancel exceptions today.  Keep the call
       outside the try/catch only as long as that contract holds; if a
       future revision adds throwing observability calls here, wrap them. *)
    let pre_compact_event =
      try
        Some
          (Dashboard_harness_health.record_pre_compact
             ~keeper_name:meta.name
             ~context_ratio:ratio
             ~message_count:msg_count
             ~token_count:tok_count
             ~strategies:strategy_names
             ~context_window:model_meta.context_window
             ~is_local_model:model_meta.is_local_model
             ~trigger)
      with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
        Log.Harness.warn
          "[pre_compact] dashboard record failed: %s"
          (Printexc.to_string exn);
        None
    in
    (match pre_compact_event with
     | None -> ()
     | Some pre_compact_event ->
       (try
          Sse.broadcast
            (`Assoc
                [ "type", `String "oas:masc:harness:pre_compact"
                ; ( "payload"
                  , `Assoc
                      [ "timestamp", `Float pre_compact_event.timestamp
                      ; "keeper_name", `String pre_compact_event.keeper_name
                      ; "context_ratio", `Float pre_compact_event.context_ratio
                      ; "message_count", `Int pre_compact_event.message_count
                      ; "token_count", `Int pre_compact_event.token_count
                      ; ( "strategies"
                        , `List
                            (List.map
                               (fun value -> `String value)
                               pre_compact_event.strategies) )
                      ; "context_window", `Int pre_compact_event.context_window
                      ; "is_local_model", `Bool pre_compact_event.is_local_model
                      ; "trigger", `String trigger_label
                      ; "trigger_detail", trigger_detail
                      ] )
                ])
        with
        | Eio.Cancel.Cancelled _ as e -> raise e
        | exn ->
          Log.Harness.warn "[pre_compact] sse broadcast failed: %s" (Printexc.to_string exn)));
    let messages, pair_repair_stats =
      let msgs_after_compact =
        (* Issue #8597 #1: dropped [~system_prompt] arg — compact
               ignored it (system prompt already present in messages
               when role=System). *)
        Context_compact_oas.compact ~messages:(messages_of_context ctx) ~strategies ()
      in
      (* Apply keeper-private fold after standard strategies *)
      let msgs_after_fold =
        Agent_sdk.Context_reducer.reduce fold_reducer msgs_after_compact
      in
      Keeper_context_core.repair_broken_tool_call_pairs_with_stats msgs_after_fold
    in
    let compacted_ctx =
      sync_oas_context
        { ctx with checkpoint = { (checkpoint_of_context ctx) with messages } }
    in
    let new_ratio = context_ratio compacted_ctx in
    let new_msg_count = message_count compacted_ctx in
    let new_tok_count = token_count compacted_ctx in
    (* [max 0 (pre - post)] silently floors the negative-delta case to
       zero. Surface that case as a counter so operators can detect
       divergence between the pre/post token (or message) measurement
       sources — without this signal, [saved_tokens=0] is ambiguous
       between "no savings" and "post-recount exceeded pre-estimate".
       The kind label is a closed 2-value vocabulary. *)
    if tok_count < new_tok_count then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_compaction_negative_savings
        ~labels:[ ("keeper", meta.name); ("kind", "tokens") ]
        ();
    if msg_count < new_msg_count then
      Prometheus.inc_counter
        Keeper_metrics.metric_keeper_compaction_negative_savings
        ~labels:[ ("keeper", meta.name); ("kind", "messages") ]
        ();
    let saved_tokens = max 0 (tok_count - new_tok_count) in
    let saved_messages = max 0 (msg_count - new_msg_count) in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_compactions
      ~labels:[ "keeper", meta.name ]
      ();
    Prometheus.set_gauge
      Keeper_metrics.metric_keeper_compaction_ratio_change
      ~labels:[ "keeper", meta.name ]
      (ratio -. new_ratio);
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_compaction_saved_tokens
      ~labels:[ "keeper", meta.name ]
      ~delta:(float_of_int saved_tokens)
      ();
    (* C1 (CRIT) from oas-internal-audit.html §6: surface pair-repair
       fabrication counts via /metrics so operators can alert on rising
       fabrication rate without grepping the JSONL [tool_pair_repair]
       structured log block emitted below. Increment by *count*, not by 1,
       so the counter reflects fabrication volume rather than call
       frequency. Kind label is a closed 2-value vocabulary (no Printexc-
       style unbounded label) — see iter 21 / PR #15788 for the same
       pattern. The repaired messages also carry [was_fabricated=true] plus
       bounded provenance under [Keeper_context_core.pair_repair_metadata_key].

       WORKAROUND-CARRYOVER: tracked by docs/rfc/RFC-0144-workaround-sunset-keeper-dedup-carryover.md
       §3 Cluster B (tool_call_pair_fabrication, PR #15792). Counter measures
       a Repair / Sanitize anti-pattern (read-side fabrication) and does not
       fix it. Root fix: write-time tool_call/tool_result pair validation at
       the LLM response boundary. *)
    let bump_pair_repair kind count =
      if count > 0
      then
        Prometheus.inc_counter
          Keeper_metrics.metric_keeper_compaction_pair_repair_fabrications
          ~labels:[ "keeper", meta.name; "kind", kind ]
          ~delta:(float_of_int count)
          ()
    in
    bump_pair_repair "downgraded_tool_use" pair_repair_stats.downgraded_tool_uses;
    bump_pair_repair "downgraded_tool_result" pair_repair_stats.downgraded_tool_results;
    Log.emit
      Log.Info
      ~module_name:"Harness"
      ~details:
        (`Assoc
            [ "keeper_name", `String meta.name
            ; "trigger", `String trigger_label
            ; "trigger_detail", trigger_detail
            ; "before_ratio", `Float ratio
            ; "after_ratio", `Float new_ratio
            ; "before_messages", `Int msg_count
            ; "after_messages", `Int new_msg_count
            ; "before_tokens", `Int tok_count
            ; "after_tokens", `Int new_tok_count
            ; "saved_messages", `Int saved_messages
            ; "saved_tokens", `Int saved_tokens
            ; ( "tool_pair_repair"
              , `Assoc
                  [ ( "downgraded_tool_uses"
                    , `Int pair_repair_stats.downgraded_tool_uses )
                  ; ( "downgraded_tool_results"
                    , `Int pair_repair_stats.downgraded_tool_results )
                  ] )
            ])
      (Printf.sprintf
         "post_compact keeper=%s trigger=%s saved_tokens=%d pair_repair_tool_uses=%d \
          pair_repair_tool_results=%d"
         meta.name
         trigger_human
         saved_tokens
         pair_repair_stats.downgraded_tool_uses
         pair_repair_stats.downgraded_tool_results);
    compacted_ctx, Some trigger, decision
;;

let compact_if_needed ~meta ~now_ts ctx =
  let ctx, trigger, decision = compact_if_needed_typed ~meta ~now_ts ctx in
  let trigger_str = Option.map Compaction_trigger.to_human trigger in
  ctx, trigger_str, compaction_decision_to_string decision
;;
