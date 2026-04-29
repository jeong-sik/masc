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
    prevents context overflow regardless of cooldown state (#5634). *)
let emergency_compact_ratio_threshold = 0.8

(** Tool-heavy compaction thresholds.
    When message count exceeds [tool_heavy_msg_threshold] AND context
    ratio exceeds [tool_heavy_ratio_floor], trigger compaction to
    stub old tool results. Prevents slow inference on local LLMs
    when many tool calls accumulate without hitting other gates. *)
let tool_heavy_msg_threshold = 40
let tool_heavy_ratio_floor = 0.15

type compaction_decision =
  | Applied of string
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_continuity_reflection of {
      hold_s : float;
      cooldown_sec : int;
    }

let compaction_decision_to_string = function
  | Applied reason -> "applied:" ^ reason
  | Blocked_below_thresholds -> "blocked:below_thresholds"
  | Skipped_no_checkpoint -> "skipped:no_checkpoint"
  | Skipped_continuity_reflection { hold_s; cooldown_sec } ->
      Printf.sprintf
        "skipped:continuity_reflection(%0.0fs<%ds)"
        hold_s cooldown_sec

let compaction_decision_applied = function
  | Applied _ -> true
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_continuity_reflection _ -> false

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  (meta.compaction.ratio_gate, meta.compaction.message_gate, meta.compaction.token_gate)

let compact_if_needed_typed
    ~(meta : keeper_meta)
    ~(now_ts : float)
    (ctx : working_context) :
    working_context * string option * compaction_decision =
  let ratio = context_ratio ctx in
  let msg_count = message_count ctx in
  (* NOTE(boundary): tok_count is raw infrastructure — ideally ratio alone
     suffices.  token_gate is kept for backward compat; most profiles
     default token_gate=0 which disables this gate.  See keeper_guard.ml. *)
  let tok_count = token_count ctx in
  let ratio_gate, message_gate, token_gate = compaction_policy_of_keeper meta in
  let cooldown = Float.of_int meta.compaction.cooldown_sec in
  let last_reflection_ts = max meta.runtime.last_continuity_update_ts meta.runtime.proactive_rt.last_ts in
  (* When no reflection has ever happened (ts=0.0), there is nothing to
     preserve — allow compaction immediately.  Also bypass the cooldown
     when context pressure is critical (ratio >= emergency_compact_ratio_threshold)
     to prevent the overflow that killed janitor at 218K/200K (#5634). *)
  let emergency = ratio >= emergency_compact_ratio_threshold in
  let reflection_ready =
    emergency
    || last_reflection_ts <= 0.0
    || (last_reflection_ts > 0.0 && now_ts -. last_reflection_ts >= cooldown)
  in
  let hold_s =
    if cooldown <= 0.0 || emergency || last_reflection_ts <= 0.0 then 0.0
    else
      max
        0.0
        (Float.of_int meta.compaction.cooldown_sec
       -. (now_ts -. last_reflection_ts))
  in
  (* Tool-heavy gate: when accumulated tool results bloat context
     without hitting ratio/message/token gates, stub old tool results
     to prevent slow inference on local LLMs (#5802).
     Bypasses reflection cooldown like the emergency ratio gate —
     tool bloat is an operational risk, not a content concern. *)
  let tool_heavy =
    (reflection_ready || emergency)
    && msg_count > tool_heavy_msg_threshold
    && ratio > tool_heavy_ratio_floor
  in
  let decision =
    if not reflection_ready then
      Skipped_continuity_reflection
        { hold_s; cooldown_sec = meta.compaction.cooldown_sec }
    else if ratio >= ratio_gate then
      Applied (Printf.sprintf "ratio(%.4f>=%.4f)" ratio ratio_gate)
    else if message_gate > 0 && msg_count >= message_gate then
      Applied (Printf.sprintf "messages(%d>=%d)" msg_count message_gate)
    else if token_gate > 0 && tok_count >= token_gate then
      Applied (Printf.sprintf "tokens(%d>=%d)" tok_count token_gate)
    else if tool_heavy then
      Applied (Printf.sprintf "tool_heavy(msgs=%d,ratio=%.4f)" msg_count ratio)
    else Blocked_below_thresholds
  in
  match decision with
  | Blocked_below_thresholds
  | Skipped_no_checkpoint
  | Skipped_continuity_reflection _ -> (ctx, None, decision)
  | Applied reason ->
      (* PreCompact observability: log strategy and context state (#3165) *)
      let strategies = Context_compact_oas.[
        PruneToolOutputs; MergeContiguous;
        DropLowImportance]
      in
      (* Use OAS stub_tool_results instead of MASC's FoldCompleted —
         OAS owns context reduction, MASC is a consumer. *)
      let fold_reducer = Oas.Context_reducer.stub_tool_results ~keep_recent:2 in
      let strategy_names =
        List.map Context_compact_oas.strategy_name strategies
        @ ["StubToolResults"]
      in
      Log.Harness.info
        "[pre_compact] keeper=%s ratio=%.4f messages=%d tokens=%d trigger=%s"
        meta.name ratio msg_count tok_count reason;
      let model_meta =
        let model_labels =
          match dedupe_keep_order (List.filter (fun s -> String.trim s <> "") meta.models) with
          | _ :: _ as explicit -> explicit
          | [] -> Cascade_runtime.models_of_cascade_name meta.cascade_name
        in
        let primary_id = match Cascade_config.parse_model_strings model_labels with
          | c :: _ -> c.Llm_provider.Provider_config.model_id | [] -> "auto" in
        Llm_provider.Model_meta.for_model_id primary_id
      in
      let pre_compact_event =
        Dashboard_harness_health.record_pre_compact
          ~keeper_name:meta.name ~context_ratio:ratio ~message_count:msg_count
          ~token_count:tok_count ~strategies:strategy_names
          ~context_window:model_meta.context_window
          ~is_local_model:model_meta.is_local ~trigger:reason
      in
      (try
         Sse.broadcast
           (`Assoc
             [
               ("type", `String "oas:masc:harness:pre_compact");
               ( "payload",
                 `Assoc
                   [
                     ("timestamp", `Float pre_compact_event.timestamp);
                     ("keeper_name", `String pre_compact_event.keeper_name);
                     ("context_ratio", `Float pre_compact_event.context_ratio);
                     ("message_count", `Int pre_compact_event.message_count);
                     ("token_count", `Int pre_compact_event.token_count);
                     ( "strategies",
                       `List
                         (List.map
                            (fun value -> `String value)
                            pre_compact_event.strategies) );
                     ("context_window", `Int pre_compact_event.context_window);
                     ("is_local_model", `Bool pre_compact_event.is_local_model);
                     ("trigger", `String pre_compact_event.trigger);
                   ] );
             ])
       with
      | Eio.Cancel.Cancelled _ as e -> raise e
      | exn ->
          Log.Harness.warn "[pre_compact] sse broadcast failed: %s"
            (Printexc.to_string exn));
      let messages =
          let msgs_after_compact =
            (* Issue #8597 #1: dropped [~system_prompt] arg — compact
               ignored it (system prompt already present in messages
               when role=System). *)
            Context_compact_oas.compact
              ~messages:(messages_of_context ctx)
              ~strategies
              ()
          in
          (* Apply keeper-private fold after standard strategies *)
          let msgs_after_fold =
            Oas.Context_reducer.reduce fold_reducer msgs_after_compact
          in
          Keeper_context_core.repair_broken_tool_call_pairs msgs_after_fold
        in
        let compacted_ctx =
          sync_oas_context
            {
              ctx with
              checkpoint = { (checkpoint_of_context ctx) with messages };
            }
        in
        let new_ratio = context_ratio compacted_ctx in
        let new_msg_count = message_count compacted_ctx in
        let new_tok_count = token_count compacted_ctx in
        let saved_tokens = max 0 (tok_count - new_tok_count) in
        let saved_messages = max 0 (msg_count - new_msg_count) in
        Prometheus.inc_counter Prometheus.metric_keeper_compactions
          ~labels:[("keeper", meta.name)] ();
        Prometheus.set_gauge Prometheus.metric_keeper_compaction_ratio_change
          ~labels:[("keeper", meta.name)]
          (ratio -. new_ratio);
        Prometheus.inc_counter Prometheus.metric_keeper_compaction_saved_tokens
          ~labels:[("keeper", meta.name)]
          ~delta:(float_of_int saved_tokens)
          ();
        Log.emit Log.Info ~module_name:"Harness"
          ~details:
            (`Assoc
              [
                ("keeper_name", `String meta.name);
                ("trigger", `String reason);
                ("before_ratio", `Float ratio);
                ("after_ratio", `Float new_ratio);
                ("before_messages", `Int msg_count);
                ("after_messages", `Int new_msg_count);
                ("before_tokens", `Int tok_count);
                ("after_tokens", `Int new_tok_count);
                ("saved_messages", `Int saved_messages);
                ("saved_tokens", `Int saved_tokens);
              ])
          (Printf.sprintf
             "post_compact keeper=%s trigger=%s saved_tokens=%d"
             meta.name reason saved_tokens);
        (compacted_ctx, Some reason, decision)

let compact_if_needed ~meta ~now_ts ctx =
  let ctx, trigger, decision = compact_if_needed_typed ~meta ~now_ts ctx in
  (ctx, trigger, compaction_decision_to_string decision)
