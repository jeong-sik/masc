(** Keeper_compact_policy — explicit compaction request application.

    Applies a caller-owned typed request. Context observations never admit
    compaction on their own.

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

type compaction_decision =
  | Applied of Compaction_trigger.t
  | Not_requested
  | Skipped_no_checkpoint

let compaction_decision_to_string = function
  | Applied trigger -> "applied:" ^ Compaction_trigger.to_human trigger
  | Not_requested -> "not_requested"
  | Skipped_no_checkpoint -> "skipped:no_checkpoint"
;;

let compaction_decision_applied = function
  | Applied _ -> true
  | Not_requested | Skipped_no_checkpoint -> false
;;

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  meta.compaction.ratio_gate, meta.compaction.message_gate, meta.compaction.token_gate
;;

let compact_for_request_typed
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
      (ctx : working_context)
  : working_context * Compaction_trigger.t option * compaction_decision
  =
  let ratio = context_ratio ctx in
  let msg_count = message_count ctx in
  let tok_count = token_count ctx in
  let decision = Applied trigger in
    let strategy_names =
      match meta.compaction.mode with
      | Keeper_config.Llm -> [ "ConfiguredLlm" ]
      | Keeper_config.Deterministic -> [ "NoLocalReducer" ]
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
      let preserve_original reason =
        Log.Keeper.warn
          ~keeper_name:meta.name
          "MASC context compaction preserved the original checkpoint: %s"
          reason;
        messages_of_context ctx
      in
      let msgs_after_compact =
        match meta.compaction.mode with
        | Keeper_config.Deterministic ->
          preserve_original
            "the retired deterministic reducer mode cannot judge message importance"
        | Keeper_config.Llm ->
          let runtime_id =
            try
              let runtime_id = Keeper_meta_contract.runtime_id_of_meta meta in
              if String.trim runtime_id = "" then None else Some runtime_id
            with
            | Failure reason ->
              Log.Keeper.warn
                ~keeper_name:meta.name
                "compaction LLM runtime identity failed: %s"
                reason;
              None
          in
          (match runtime_id with
           | None -> preserve_original "configured LLM runtime is unavailable"
           | Some runtime_id ->
             (match
                Keeper_compaction_llm_summarizer.make
                  ~runtime_id
                  ~keeper_name:meta.name
                  ()
              with
              | None -> preserve_original "configured LLM summarizer is unavailable"
              | Some summarizer ->
                let msgs = messages_of_context ctx in
                (match summarizer ~messages:msgs with
                 | Some plan ->
                   Keeper_compaction_llm_summarizer.apply plan ~messages:msgs
                 | None ->
                   preserve_original "configured LLM returned no valid plan")))
      in
      Keeper_context_core.repair_broken_tool_call_pairs_with_stats msgs_after_compact
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
