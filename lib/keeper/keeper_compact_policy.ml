(** Keeper_compact_policy — explicit compaction request application.

    Applies a caller-owned typed request. Context observations never admit
    compaction on their own.

    Extracted from Keeper_context_runtime as part of #4955 god-file split. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_context_core

type pre_compact_event =
  { timestamp : float
  ; keeper_name : string
  ; checkpoint_bytes : int
  ; message_count : int
  ; strategies : string list
  ; trigger : Compaction_trigger.t
  }

let record_pre_compact_callback_atomic
    : (keeper_name:string
       -> checkpoint_bytes:int
       -> message_count:int
       -> strategies:string list
       -> trigger:Compaction_trigger.t
       -> pre_compact_event option)
        Atomic.t
  =
  Atomic.make
    (fun
      ~keeper_name:_
      ~checkpoint_bytes:_
      ~message_count:_
      ~strategies:_
      ~trigger:_
    -> None)
;;

let record_pre_compact_callback
      ~keeper_name
      ~checkpoint_bytes
      ~message_count
      ~strategies
      ~trigger
  =
  Atomic.get record_pre_compact_callback_atomic
    ~keeper_name
    ~checkpoint_bytes
    ~message_count
    ~strategies
    ~trigger
;;

let register_record_pre_compact
    (f :
      keeper_name:string
      -> checkpoint_bytes:int
      -> message_count:int
      -> strategies:string list
      -> trigger:Compaction_trigger.t
      -> pre_compact_event option)
  =
  Atomic.set record_pre_compact_callback_atomic f
;;

type compaction_rejection_reason =
  | Retired_deterministic_mode
  | Runtime_identity_unavailable
  | Summarizer_unavailable
  | Plan_unavailable_or_invalid
  | Structurally_unchanged
  | Checkpoint_not_reduced

let compaction_rejection_reason_to_string = function
  | Retired_deterministic_mode -> "retired_deterministic_mode"
  | Runtime_identity_unavailable -> "runtime_identity_unavailable"
  | Summarizer_unavailable -> "summarizer_unavailable"
  | Plan_unavailable_or_invalid -> "plan_unavailable_or_invalid"
  | Structurally_unchanged -> "structurally_unchanged"
  | Checkpoint_not_reduced -> "checkpoint_not_reduced"
;;

type compaction_decision =
  | Applied of Compaction_trigger.t
  | Rejected of
      { trigger : Compaction_trigger.t
      ; reason : compaction_rejection_reason
      }
  | Not_requested
  | Skipped_no_checkpoint

let compaction_decision_to_string = function
  | Applied trigger -> "applied:" ^ Compaction_trigger.to_human trigger
  | Rejected { trigger; reason } ->
    Printf.sprintf
      "rejected:%s:%s"
      (Compaction_trigger.to_label trigger)
      (compaction_rejection_reason_to_string reason)
  | Not_requested -> "not_requested"
  | Skipped_no_checkpoint -> "skipped:no_checkpoint"
;;

let compaction_decision_applied = function
  | Applied _ -> true
  | Rejected _ | Not_requested | Skipped_no_checkpoint -> false
;;

let compaction_policy_of_keeper (meta : keeper_meta) : float * int * int =
  meta.compaction.ratio_gate, meta.compaction.message_gate, meta.compaction.token_gate
;;

let strategy_names (meta : keeper_meta) =
  match meta.compaction.mode with
  | Keeper_config.Llm -> [ "ConfiguredLlm" ]
  | Keeper_config.Deterministic -> [ "NoLocalReducer" ]
;;

let record_pre_compact
      ~(meta : keeper_meta)
      ~checkpoint_bytes
      ~message_count
      ~strategies
      ~trigger
  =
  let event =
    try
      Atomic.get record_pre_compact_callback_atomic
        ~keeper_name:meta.name
        ~checkpoint_bytes
        ~message_count
        ~strategies
        ~trigger
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Log.Harness.warn
        "[pre_compact] dashboard record failed: %s"
        (Printexc.to_string exn);
      None
  in
  match event with
  | None -> ()
  | Some event ->
    (try
       Sse.broadcast
         (`Assoc
             [ "type", `String "oas:masc:harness:pre_compact"
             ; ( "payload"
               , `Assoc
                   [ "timestamp", `Float event.timestamp
                   ; "keeper_name", `String event.keeper_name
                   ; "checkpoint_bytes", `Int event.checkpoint_bytes
                   ; "message_count", `Int event.message_count
                   ; ( "strategies"
                     , `List (List.map (fun value -> `String value) event.strategies) )
                   ; "trigger", `String (Compaction_trigger.to_label event.trigger)
                   ; "trigger_detail", Compaction_trigger.to_detail_json event.trigger
                   ] )
             ])
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Harness.warn
         "[pre_compact] sse broadcast failed: %s"
         (Printexc.to_string exn))
;;

let requested_messages (meta : keeper_meta) messages =
  match meta.compaction.mode with
  | Keeper_config.Deterministic -> Error Retired_deterministic_mode
  | Keeper_config.Llm ->
    let runtime_id =
      try
        let runtime_id = Keeper_meta_contract.runtime_id_of_meta meta in
        if String.trim runtime_id = ""
        then Error Runtime_identity_unavailable
        else Ok runtime_id
      with
      | Failure _ -> Error Runtime_identity_unavailable
    in
    (match runtime_id with
     | Error _ as error -> error
     | Ok runtime_id ->
       (match
          Keeper_compaction_llm_summarizer.make
            ~runtime_id
            ~keeper_name:meta.name
            ()
        with
        | None -> Error Summarizer_unavailable
        | Some summarize ->
          (match summarize ~messages with
           | None -> Error Plan_unavailable_or_invalid
           | Some plan ->
             if plan.summarized = [] && plan.dropped = []
             then Error Structurally_unchanged
             else
               Ok (Keeper_compaction_llm_summarizer.apply plan ~messages))))
;;

let log_rejection ~meta ~trigger ~reason ~checkpoint_bytes ~message_count =
  let reason_label = compaction_rejection_reason_to_string reason in
  Log.Harness.emit
    Log.Warn
    ~details:
      (`Assoc
          [ "keeper_name", `String meta.name
          ; "trigger", `String (Compaction_trigger.to_label trigger)
          ; "trigger_detail", Compaction_trigger.to_detail_json trigger
          ; "reason", `String reason_label
          ; "checkpoint_bytes", `Int checkpoint_bytes
          ; "message_count", `Int message_count
          ])
    (Printf.sprintf
       "compaction_rejected keeper=%s trigger=%s reason=%s"
       meta.name
       (Compaction_trigger.to_human trigger)
       reason_label)
;;

let log_pair_repair ~keeper_name stats =
  let bump kind count =
    if count > 0
    then
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string CompactionPairRepairDrops)
        ~labels:[ "keeper", keeper_name; "kind", kind ]
        ~delta:(float_of_int count)
        ()
  in
  bump "dropped_tool_use" stats.dropped_tool_uses;
  bump "dropped_tool_result" stats.dropped_tool_results
;;

let compact_for_request_typed
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
      (ctx : working_context)
  : working_context * Compaction_trigger.t option * compaction_decision
  =
  let before_bytes = serialized_bytes ctx in
  let before_messages = message_count ctx in
  let strategies = strategy_names meta in
  record_pre_compact
    ~meta
    ~checkpoint_bytes:before_bytes
    ~message_count:before_messages
    ~strategies
    ~trigger;
  match requested_messages meta (messages_of_context ctx) with
  | Error reason ->
    log_rejection
      ~meta
      ~trigger
      ~reason
      ~checkpoint_bytes:before_bytes
      ~message_count:before_messages;
    ctx, None, Rejected { trigger; reason }
  | Ok requested ->
    let messages, pair_repair_stats =
      Keeper_context_core.repair_broken_tool_call_pairs_with_stats requested
    in
    let compacted_ctx =
      sync_oas_context
        { ctx with checkpoint = { (checkpoint_of_context ctx) with messages } }
    in
    let after_bytes = serialized_bytes compacted_ctx in
    let after_messages = message_count compacted_ctx in
    if after_bytes = before_bytes
    then (
      let reason = Structurally_unchanged in
      log_rejection
        ~meta
        ~trigger
        ~reason
        ~checkpoint_bytes:before_bytes
        ~message_count:before_messages;
      ctx, None, Rejected { trigger; reason })
    else if after_bytes > before_bytes
    then (
      let reason = Checkpoint_not_reduced in
      log_rejection
        ~meta
        ~trigger
        ~reason
        ~checkpoint_bytes:before_bytes
        ~message_count:before_messages;
      ctx, None, Rejected { trigger; reason })
    else (
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string Compactions)
        ~labels:[ "keeper", meta.name ]
        ();
      log_pair_repair ~keeper_name:meta.name pair_repair_stats;
      Log.Harness.emit
        Log.Info
        ~details:
          (`Assoc
              [ "keeper_name", `String meta.name
              ; "trigger", `String (Compaction_trigger.to_label trigger)
              ; "trigger_detail", Compaction_trigger.to_detail_json trigger
              ; "before_checkpoint_bytes", `Int before_bytes
              ; "after_checkpoint_bytes", `Int after_bytes
              ; "saved_checkpoint_bytes", `Int (before_bytes - after_bytes)
              ; "before_messages", `Int before_messages
              ; "after_messages", `Int after_messages
              ; ( "tool_pair_repair"
                , `Assoc
                    [ "dropped_tool_uses", `Int pair_repair_stats.dropped_tool_uses
                    ; ( "dropped_tool_results"
                      , `Int pair_repair_stats.dropped_tool_results )
                    ] )
              ])
        (Printf.sprintf
           "post_compact keeper=%s trigger=%s saved_checkpoint_bytes=%d"
           meta.name
           (Compaction_trigger.to_human trigger)
           (before_bytes - after_bytes));
      compacted_ctx, Some trigger, Applied trigger)
;;
