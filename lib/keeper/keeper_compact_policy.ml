(** Keeper_compact_policy — compaction gate and strategy application.

    Decides whether compaction should run based on ratio/message/token
    gates and cooldown, then applies OAS strategies + persona fold.

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

type pre_compact_event = {
  timestamp : float;
  keeper_name : string;
  context_ratio : float;
  message_count : int;
  token_count : int;
  strategies : string list;
  context_window : int;
  is_local_model : bool;
  trigger : Compaction_trigger.t;
}

let record_pre_compact_callback_atomic
    : (keeper_name:string -> context_ratio:float -> message_count:int -> token_count:int -> strategies:string list -> context_window:int -> is_local_model:bool -> trigger:Compaction_trigger.t -> pre_compact_event option)
      Atomic.t
  =
  Atomic.make
    (fun ~keeper_name:_ ~context_ratio:_ ~message_count:_ ~token_count:_ ~strategies:_ ~context_window:_ ~is_local_model:_ ~trigger:_ -> None)
;;

let record_pre_compact_callback
    ~keeper_name
    ~context_ratio
    ~message_count
    ~token_count
    ~strategies
    ~context_window
    ~is_local_model
    ~trigger
  =
  Atomic.get record_pre_compact_callback_atomic
    ~keeper_name
    ~context_ratio
    ~message_count
    ~token_count
    ~strategies
    ~context_window
    ~is_local_model
    ~trigger

let register_record_pre_compact
    (f :
       keeper_name:string
       -> context_ratio:float
       -> message_count:int
       -> token_count:int
       -> strategies:string list
       -> context_window:int
       -> is_local_model:bool
       -> trigger:Compaction_trigger.t
       -> pre_compact_event option)
  =
  Atomic.set record_pre_compact_callback_atomic f
;;

let pre_compact_is_local_model_of_meta meta =
  let runtime_id_result =
    try Ok (Keeper_meta_contract.runtime_id_of_meta meta) with
    | Failure msg -> Error msg
  in
  match runtime_id_result with
  | Error msg ->
    (* DET-OK: pre-compact locality is observability only. Do not let a
       startup-order failure in the default-runtime singleton block
       compaction itself. *)
    Log.Harness.warn
      "[pre_compact] runtime locality unavailable for keeper=%s: %s; \
       recording is_local_model=false"
      meta.name
      msg;
    false
  | Ok runtime_id ->
    (match Runtime.is_local_runtime_id runtime_id with
     | Some is_local -> is_local
     | None ->
       (* DET-OK: runtime dispatch owns fail-fast validation. This metric
          only records locality when the runtime table is already materialized. *)
       Log.Harness.warn
         "[pre_compact] runtime locality unavailable for runtime_id=%s; \
          recording is_local_model=false"
         runtime_id;
       false)
;;

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
    boot). The effective value is exposed via Otel_metric_store gauge
    {!Keeper_metrics.(to_string EmergencyCompactRatioThreshold)}
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
     then suppresses the warn path entirely. (Review on PR #15782.) *)
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
  (* Surface the effective value for operators via telemetry export. Registered
     here so the gauge exists from module init regardless of whether any
     compaction has fired yet. *)
  Otel_metric_store.register_gauge
    ~name:Keeper_metrics.(to_string EmergencyCompactRatioThreshold)
    ~help:
      "Effective emergency compaction ratio threshold (env-overridable via \
       MASC_KEEPER_EMERGENCY_COMPACT_RATIO_THRESHOLD; clamped to [0.5, 0.99])."
    ();
  Otel_metric_store.set_gauge
    Keeper_metrics.(to_string EmergencyCompactRatioThreshold)
    effective;
  effective
;;

(* The former tool_heavy trigger (msg_count > 40 && ratio > 0.15,
   cooldown-bypassing) was removed: it gated on stored-history bulk that the
   OAS call-time pruner (Agent_turn.prepare_messages: stub_tool_results
   keep_recent + keep_last, applied on every LLM call without mutating
   stored history) already bounds, while its destructive remedy
   (prune/stub/drop on the checkpoint) erased in-flight investigation
   state and did not push msg_count back under its own threshold —
   re-arming itself within seconds.  Fleet logs 2026-06-08..10: 26/26
   compactions fired via tool_heavy, none via the pressure gates below;
   68k tokens saved vs ~1.2-2.6M re-spent on forced re-reads.
   Real context pressure remains covered by ratio/message/token gates,
   the emergency floor above, and the OAS overflow-retry summarizer. *)

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
  if not reflection_ready
  then Skipped_continuity_reflection { hold_s; cooldown_sec }
  else if ratio >= ratio_gate
  then Applied (Compaction_trigger.Ratio_threshold { ratio; threshold = ratio_gate })
  else if message_gate > 0 && msg_count >= message_gate
  then Applied (Compaction_trigger.Message_count { count = msg_count; threshold = message_gate })
  else if token_gate > 0 && tok_count >= token_gate
  then Applied (Compaction_trigger.Token_count { count = tok_count; threshold = token_gate })
  else Blocked_below_thresholds
;;

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  meta.compaction.ratio_gate, meta.compaction.message_gate, meta.compaction.token_gate
;;

let deterministic_checkpoint_strategies =
  Context_compact_oas.
    [ PruneToolOutputs; MergeContiguous; SummarizeOld; DropLowImportance ]
;;

(* RFC-0313-adjacent: expose the extractive OAS chain used for checkpoint
   observability and as the deterministic floor. In [Llm] mode the actual
   provider-backed plan is selected in [compact_if_needed_typed] when the
   compaction is not an emergency; unavailable or invalid provider plans
   fall back to this chain. *)
let checkpoint_compaction_strategies ~(mode : Keeper_config.compaction_mode) =
  match mode with
  | Keeper_config.Deterministic -> deterministic_checkpoint_strategies
  | Keeper_config.Llm ->
    deterministic_checkpoint_strategies
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
    let strategies = checkpoint_compaction_strategies ~mode:meta.compaction.mode in
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
    let pre_compact_context_window = max_tokens_of_context ctx in
    let pre_compact_is_local_model = pre_compact_is_local_model_of_meta meta in
    (* record_pre_compact's JSONL append is wrapped by
       append_store_json_fail_open in Dashboard_harness_health, so this call
       does not propagate non-Cancel exceptions today.  Keep the call
       outside the try/catch only as long as that contract holds; if a
       future revision adds throwing observability calls here, wrap them. *)
    let pre_compact_event =
      try
        Atomic.get record_pre_compact_callback_atomic
          ~keeper_name:meta.name
          ~context_ratio:ratio
          ~message_count:msg_count
          ~token_count:tok_count
          ~strategies:strategy_names
          ~context_window:pre_compact_context_window
          ~is_local_model:pre_compact_is_local_model
          ~trigger
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
    (match pre_compact_event with
     | None -> ()
     | Some _ ->
       Keeper_event_publisher.publish_keeper_snapshot
         ~keeper_name:meta.name
         ~generation:meta.runtime.generation
         ~context_ratio:ratio
         ~message_count:msg_count);
    let messages, pair_repair_stats =
      let deterministic_compact () =
        (* Issue #8597 #1: dropped [~system_prompt] arg — compact
               ignored it (system prompt already present in messages
               when role=System). *)
        Context_compact_oas.compact ~messages:(messages_of_context ctx) ~strategies ()
      in
      (* RFC-0313-adjacent W2: [Llm] mode asks a librarian-lane summarizer for a
         structured kept/summarized/dropped plan and applies it; any failure
         (no Eio context, no schema provider, invalid plan) yields
         [None] and falls back to the deterministic chain — the [Deterministic]
         floor is always the guaranteed result. Emergency compaction (a
         near-full context, [emergency] above) never calls the LLM: the reply
         itself needs headroom and the cooldown is bypassed, so it stays on the
         cheap deterministic path. *)
      let msgs_after_compact =
        match meta.compaction.mode with
        | Keeper_config.Deterministic -> deterministic_compact ()
        | Keeper_config.Llm ->
          let emergency = ratio >= emergency_compact_ratio_threshold in
          if emergency
          then deterministic_compact ()
          else
            let runtime_id =
              try
                let runtime_id = Keeper_meta_contract.runtime_id_of_meta meta in
                if String.trim runtime_id = ""
                then (
                  Log.Keeper.warn ~keeper_name:meta.name
                    "compaction LLM summarizer skipped: runtime identity resolved to an empty \
                     id; using deterministic fallback";
                  None)
                else Some runtime_id
              with
              | Failure reason ->
                Log.Keeper.warn ~keeper_name:meta.name
                  "compaction LLM summarizer runtime identity failed: %s; using \
                   deterministic fallback"
                  reason;
                None
            in
            (match runtime_id with
             | None -> deterministic_compact ()
             | Some runtime_id ->
               (match
                  Keeper_compaction_llm_summarizer.make
                    ~runtime_id
                    ~keeper_name:meta.name
                    ()
                with
                | None -> deterministic_compact ()
                | Some summarizer ->
                  let msgs = messages_of_context ctx in
                  (match summarizer ~messages:msgs with
                   | Some plan ->
                     Keeper_compaction_llm_summarizer.apply plan ~messages:msgs
                   | None -> deterministic_compact ())))
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
    (* RFC-0149 §3.2 PR-2 — the silent [max 0 (pre - post)] floor and
       the companion [metric_keeper_compaction_negative_savings] counter
       (a §1 telemetry-as-fix artefact) are replaced by a phantom-typed
       [Keeper_token_count.saved] match.  The [`Divergent] arm carries the
       overrun magnitude as a typed payload that surfaces on the
       post-compact JSONL record below ([tokens_divergence] /
       [messages_divergence]), so operators can detect estimator
       drift without a free-floating Otel_metric_store counter. *)
    let saved_tokens, tokens_divergence =
      match
        Keeper_token_count.saved
          ~pre:(Keeper_token_count.pre_estimate tok_count)
          ~post:(Keeper_token_count.post_recount new_tok_count)
      with
      | `Saved n -> n, None
      | `Divergent n -> 0, Some n
    in
    let saved_messages, messages_divergence =
      match
        Keeper_token_count.saved
          ~pre:(Keeper_token_count.pre_estimate msg_count)
          ~post:(Keeper_token_count.post_recount new_msg_count)
      with
      | `Saved n -> n, None
      | `Divergent n -> 0, Some n
    in
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string Compactions)
      ~labels:[ "keeper", meta.name ]
      ();
    Otel_metric_store.set_gauge
      Keeper_metrics.(to_string CompactionRatioChange)
      ~labels:[ "keeper", meta.name ]
      (ratio -. new_ratio);
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string CompactionSavedTokens)
      ~labels:[ "keeper", meta.name ]
      ~delta:(float_of_int saved_tokens)
      ();
    (* C1 (CRIT) from oas-internal-audit.html §6: surface pair-repair
       counts via telemetry export so operators can alert on rising repair
       rate without grepping the JSONL [tool_pair_repair] structured log block
       emitted below. Increment by *count*, not by 1, so the counter reflects
       repair volume rather than call frequency. Kind label is a closed
       2-value vocabulary (no Printexc-style unbounded label) — see iter 21 /
       PR #15788 for the same pattern. The repaired messages also carry
       bounded provenance under [Keeper_context_core.pair_repair_metadata_key]. *)
    let bump_pair_repair kind count =
      if count > 0
      then
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string CompactionPairRepairDrops)
          ~labels:[ "keeper", meta.name; "kind", kind ]
          ~delta:(float_of_int count)
          ()
    in
    bump_pair_repair "dropped_tool_use" pair_repair_stats.dropped_tool_uses;
    bump_pair_repair "dropped_tool_result" pair_repair_stats.dropped_tool_results;
    let tool_use_sample_json =
      List.map
        (fun (tool_use_id, tool_name) ->
           `Assoc
             [ "tool_use_id", `String tool_use_id
             ; "tool_name", `String tool_name
             ])
        pair_repair_stats.dropped_tool_use_samples
    in
    let tool_result_id_json =
      List.map
        (fun tool_use_id -> `String tool_use_id)
        pair_repair_stats.dropped_tool_result_ids
    in
    Log.Harness.emit
      Log.Info
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
            ; ( "tokens_divergence"
              , match tokens_divergence with
                | Some n -> `Int n
                | None -> `Null )
            ; ( "messages_divergence"
              , match messages_divergence with
                | Some n -> `Int n
                | None -> `Null )
            ; ( "tool_pair_repair"
              , `Assoc
                  [ ( "dropped_tool_uses"
                    , `Int pair_repair_stats.dropped_tool_uses )
                  ; ( "dropped_tool_results"
                    , `Int pair_repair_stats.dropped_tool_results )
                  ; "dropped_tool_use_samples", `List tool_use_sample_json
                  ; "dropped_tool_result_ids", `List tool_result_id_json
                  ] )
            ])
      (Printf.sprintf
         "post_compact keeper=%s trigger=%s saved_tokens=%d pair_repair_dropped_tool_uses=%d \
          pair_repair_dropped_tool_results=%d"
         meta.name
         trigger_human
         saved_tokens
         pair_repair_stats.dropped_tool_uses
         pair_repair_stats.dropped_tool_results);
    compacted_ctx, Some trigger, decision
;;

let compact_if_needed ~meta ~now_ts ctx =
  let ctx, trigger, decision = compact_if_needed_typed ~meta ~now_ts ctx in
  let trigger_str = Option.map Compaction_trigger.to_human trigger in
  ctx, trigger_str, compaction_decision_to_string decision
;;
