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

type compaction_rejection =
  | Retired_deterministic_mode
  | Runtime_identity_unavailable
  | Summarizer_unavailable
  | Plan_unavailable_or_invalid
  | Structurally_unchanged
  | Checkpoint_not_reduced

let compaction_rejection_to_string = function
  | Retired_deterministic_mode -> "retired_deterministic_mode"
  | Runtime_identity_unavailable -> "runtime_identity_unavailable"
  | Summarizer_unavailable -> "summarizer_unavailable"
  | Plan_unavailable_or_invalid -> "plan_unavailable_or_invalid"
  | Structurally_unchanged -> "structurally_unchanged"
  | Checkpoint_not_reduced -> "checkpoint_not_reduced"
;;

type compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

type compaction_evidence =
  { selected_runtime_id : string option
  ; before_checkpoint_bytes : int
  ; after_checkpoint_bytes : int
  ; before_message_count : int
  ; after_message_count : int
  ; summarized_message_count : int
  ; dropped_message_count : int
  ; before_tool_use_count : int
  ; after_tool_use_count : int
  ; before_tool_result_count : int
  ; after_tool_result_count : int
  }

type compaction_preparation =
  { context : working_context
  ; decision : compaction_decision
  ; evidence : compaction_evidence option
  }

let compaction_decision_to_string = function
  | Applied trigger -> "applied:" ^ Compaction_trigger.to_human trigger
  | Prepared trigger -> "prepared:" ^ Compaction_trigger.to_human trigger
  | Rejected (trigger, reason) ->
    Printf.sprintf
      "rejected:%s:%s"
      (compaction_rejection_to_string reason)
      (Compaction_trigger.to_human trigger)
  | Not_requested -> "not_requested"
  | Skipped_no_checkpoint -> "skipped:no_checkpoint"
;;

let compaction_decision_prepared = function
  | Prepared _ -> true
  | Applied _ | Rejected _ | Not_requested | Skipped_no_checkpoint -> false
;;

let compaction_decision_applied = function
  | Applied _ -> true
  | Prepared _ | Rejected _ | Not_requested | Skipped_no_checkpoint -> false
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

type requested_compaction =
  { messages : Agent_sdk.Types.message list
  ; selected_runtime_id : string option
  ; summarized_message_count : int
  ; dropped_message_count : int
  }

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
               Ok
                 { messages = Keeper_compaction_llm_summarizer.apply plan ~messages
                 ; selected_runtime_id = plan.selected_runtime_id
                 ; summarized_message_count = List.length plan.summarized
                 ; dropped_message_count = List.length plan.dropped
                 })))
;;

let tool_block_counts messages =
  let rec count_blocks (uses, results) blocks =
    List.fold_left
      (fun (uses, results) -> function
         | Agent_sdk.Types.ToolUse _ -> uses + 1, results
         | Agent_sdk.Types.ToolResult { content_blocks; _ } ->
           let counts = uses, results + 1 in
           Option.fold ~none:counts ~some:(count_blocks counts) content_blocks
         | Agent_sdk.Types.Text _
         | Agent_sdk.Types.Thinking _
         | Agent_sdk.Types.ReasoningDetails _
         | Agent_sdk.Types.RedactedThinking _
         | Agent_sdk.Types.Image _
         | Agent_sdk.Types.Document _
         | Agent_sdk.Types.Audio _ ->
           uses, results)
      (uses, results)
      blocks
  in
  List.fold_left
    (fun counts (message : Agent_sdk.Types.message) ->
       count_blocks counts message.content)
    (0, 0)
    messages
;;

let log_rejection ~meta ~trigger ~reason ~checkpoint_bytes ~message_count =
  let reason_label = compaction_rejection_to_string reason in
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

let compact_for_request_typed
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
      (ctx : working_context)
  : compaction_preparation
  =
  let before_bytes = serialized_bytes ctx in
  let before_messages = message_count ctx in
  record_pre_compact
    ~meta
    ~checkpoint_bytes:before_bytes
    ~message_count:before_messages
    ~strategies:(strategy_names meta)
    ~trigger;
  match requested_messages meta (messages_of_context ctx) with
  | Error reason ->
    log_rejection
      ~meta
      ~trigger
      ~reason
      ~checkpoint_bytes:before_bytes
      ~message_count:before_messages;
    { context = ctx; decision = Rejected (trigger, reason); evidence = None }
  | Ok requested ->
    let messages, pair_repair_stats =
      Keeper_context_core.repair_broken_tool_call_pairs_with_stats requested.messages
    in
    let compacted_ctx =
      sync_oas_context
        { ctx with checkpoint = { (checkpoint_of_context ctx) with messages } }
    in
    let after_bytes = serialized_bytes compacted_ctx in
    let reject reason =
      log_rejection
        ~meta
        ~trigger
        ~reason
        ~checkpoint_bytes:before_bytes
        ~message_count:before_messages;
      { context = ctx; decision = Rejected (trigger, reason); evidence = None }
    in
    if after_bytes = before_bytes
    then reject Structurally_unchanged
    else if after_bytes > before_bytes
    then reject Checkpoint_not_reduced
    else (
      let after_messages = message_count compacted_ctx in
      let before_tool_use_count, before_tool_result_count =
        tool_block_counts (messages_of_context ctx)
      in
      let after_tool_use_count, after_tool_result_count =
        tool_block_counts (messages_of_context compacted_ctx)
      in
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
              ; "trigger", `String (Compaction_trigger.to_label trigger)
              ; "trigger_detail", Compaction_trigger.to_detail_json trigger
              ; "before_checkpoint_bytes", `Int before_bytes
              ; "after_checkpoint_bytes", `Int after_bytes
              ; "saved_checkpoint_bytes", `Int (before_bytes - after_bytes)
              ; "before_messages", `Int before_messages
              ; "after_messages", `Int after_messages
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
           "context compaction prepared keeper=%s saved_checkpoint_bytes=%d"
           meta.name
           (before_bytes - after_bytes));
      { context = compacted_ctx
      ; decision = Prepared trigger
      ; evidence =
          Some
            { selected_runtime_id = requested.selected_runtime_id
            ; before_checkpoint_bytes = before_bytes
            ; after_checkpoint_bytes = after_bytes
            ; before_message_count = before_messages
            ; after_message_count = after_messages
            ; summarized_message_count = requested.summarized_message_count
            ; dropped_message_count = requested.dropped_message_count
            ; before_tool_use_count
            ; after_tool_use_count
            ; before_tool_result_count
            ; after_tool_result_count
            }
      })
;;
