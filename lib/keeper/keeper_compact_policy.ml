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

include Keeper_compact_rejection

type compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

type compaction_preparation =
  { context : working_context
  ; decision : compaction_decision
  ; evidence : Keeper_compaction_evidence.t option
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

let strategy_names = [ "ConfiguredLlm" ]

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
             [ "type", `String "agent_core:masc:harness:pre_compact"
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
  { messages : Agent_core.Types.message list
  ; exact_execution_evidence :
      Keeper_compaction_llm_summarizer.exact_execution_evidence
  ; summarized_message_count : int
  ; dropped_message_count : int
  ; plan_accounting : plan_accounting
  }

and plan_accounting =
  { expected_after_message_count : int
  ; expected_after_tool_use_count : int
  ; expected_after_tool_result_count : int
  }

let unit_message_count = function
  | Keeper_compaction_unit.Ordinary_message _ -> 1
  | Keeper_compaction_unit.Closed_tool_cycle messages -> List.length messages
;;

let selected_message_count units selected =
  let units = Array.of_list units in
  List.fold_left
    (fun count index -> count + unit_message_count units.(index))
    0
    selected
;;

let tool_block_counts messages =
  let rec count_blocks (uses, results) blocks =
    List.fold_left
      (fun (uses, results) -> function
         | Agent_core.Types.ToolUse _ -> uses + 1, results
         | Agent_core.Types.ToolResult { content_blocks; _ } ->
           let counts = uses, results + 1 in
           Option.fold ~none:counts ~some:(count_blocks counts) content_blocks
         | Agent_core.Types.Text _
         | Agent_core.Types.Thinking _
         | Agent_core.Types.ReasoningDetails _
         | Agent_core.Types.RedactedThinking _
         | Agent_core.Types.Image _
         | Agent_core.Types.Document _
         | Agent_core.Types.Audio _ ->
           uses, results)
      (uses, results)
      blocks
  in
  List.fold_left
    (fun counts (message : Agent_core.Types.message) ->
       count_blocks counts message.content)
    (0, 0)
    messages
;;

let terminal_rejection exact_execution_evidence cause =
  Exact_execution_terminal
    (Keeper_compaction_llm_summarizer.exact_execution_terminal
       ~cause
       exact_execution_evidence)
;;

let requested_messages_with_plan
      ~(plan_for_units :
         units:Keeper_compaction_unit.closed_unit list ->
         ( Keeper_compaction_llm_summarizer.completed_plan
         , Keeper_compaction_llm_summarizer.summarization_failure )
           result)
      messages
  =
  match Keeper_compaction_unit.partition ~quarantine:true messages with
  | Error error -> Error (Invalid_structure error)
  | Ok { closed_prefix = units; protected_suffix } ->
    (* Persistence-gate precondition, checked BEFORE the summarizer runs.

       [partition ~quarantine:true] tolerates a structural break by freezing
       the valid prefix and moving the break plus its successors into
       [protected_suffix]. The persist boundary does not tolerate it: a
       checkpoint must preserve every message exactly, so it runs
       [Keeper_compaction_unit.validate] with quarantine off
       (keeper_context_core.ml:71 -> Tool_history_invalid ->
       Invalid_structural_source). Because quarantine PRESERVES the break in
       [protected_suffix], that break is carried into the compacted checkpoint
       and rejected there — after the summarizer call has already been paid
       for. [validate messages] failing therefore implies the compacted result
       fails too, so rejecting here refuses no compaction that could have
       persisted.

       Without this precheck, the same canonical validator rejects only at the
       checkpoint boundary after the exact-output call has already run.
       [commit_prepared_compaction] now returns that late refusal as typed
       [Not_committed]; checking here preserves the same feature result while
       avoiding a provider call that cannot produce a persistable checkpoint.

       Terminating is correct here because [validate] rejection is monotone
       under append: appending messages never repairs an existing structural
       break, so retrying the identical source cannot succeed.

       Because this gate precedes summarizer selection, a keeper with BOTH a
       broken history and an unavailable summarizer now reports
       [Invalid_structure] (terminal) rather than [Summarizer_unavailable]
       (retryable). That ordering is intended: the structural break is the
       condition that no retry can clear.

       Scope: this stops the retry loop and its cost. It does not make a
       structurally broken history compactable — the break has to be prevented
       at the write boundary that admitted a tool_use with no matching
       tool_result (#25443). *)
    (match Keeper_compaction_unit.validate messages with
     | Error error -> Error (Invalid_structure error)
     | Ok () ->
    if units = []
    then Error No_eligible_history
    else if not (Keeper_compaction_llm_summarizer.has_eligible_units units)
    then Error No_eligible_history
    else
      (match plan_for_units ~units with
       | Error failure -> Error (summarization_rejection failure)
       | Ok completed ->
         let plan = Keeper_compaction_llm_summarizer.completed_plan completed in
         let exact_execution_evidence =
           Keeper_compaction_llm_summarizer.completed_exact_execution_evidence
             completed
         in
         let summarized_indices =
           Keeper_compaction_llm_summarizer.summarized_indices plan
         in
         let dropped_indices =
           Keeper_compaction_llm_summarizer.dropped_indices plan
         in
         let messages =
           Keeper_compaction_llm_summarizer.apply plan @ protected_suffix
         in
         let expected_after_tool_use_count, expected_after_tool_result_count =
           tool_block_counts messages
         in
            if not (Keeper_compaction_llm_summarizer.has_changes plan)
            then
              Error
                (terminal_rejection
                   exact_execution_evidence
                   Keeper_compaction_outcome.Domain_invalid_output)
            else
              Ok
                { messages
                ; exact_execution_evidence
                ; summarized_message_count =
                    selected_message_count
                      units
                      summarized_indices
                ; dropped_message_count =
                    selected_message_count
                      units
                      dropped_indices
                ; plan_accounting =
                    { expected_after_message_count = List.length messages
                    ; expected_after_tool_use_count
                    ; expected_after_tool_result_count
                    }
                }))
;;

let requested_messages
      ?before_dispatch_authority
      ~base_path
      (meta : keeper_meta)
      messages
  =
  requested_messages_with_plan
    ~plan_for_units:(fun ~units ->
      match
        Keeper_compaction_llm_summarizer.make
          ?before_dispatch_authority
          ~base_path
          ~keeper_name:meta.name
          ()
      with
      | None -> Error Keeper_compaction_llm_summarizer.Exact_execution_context_unavailable
      | Some summarize -> summarize ~units)
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

let compact_for_request_typed_with
      ~requested_messages
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
    ~strategies:strategy_names
    ~trigger;
  match requested_messages (messages_of_context ctx) with
  | Error reason ->
    log_rejection
      ~meta
      ~trigger
      ~reason
      ~checkpoint_bytes:before_bytes
      ~message_count:before_messages;
    { context = ctx
    ; decision = Rejected (trigger, reason)
    ; evidence = None
    }
  | Ok requested ->
    let checkpoint =
      { (checkpoint_of_context ctx) with messages = requested.messages }
    in
    let compacted_ctx =
      sync_agent_core_context { checkpoint }
    in
    let after_bytes = serialized_bytes compacted_ctx in
    let reject reason =
      log_rejection
        ~meta
        ~trigger
        ~reason
        ~checkpoint_bytes:before_bytes
        ~message_count:before_messages;
      { context = ctx
      ; decision = Rejected (trigger, reason)
      ; evidence = None
      }
    in
    (* Both outcomes are terminal for this attempt, and both used to report
       [Domain_invalid_output]. That label is defensible — the contract is that only a
       strictly reducing plan is prepared, so a plan that does not reduce did not
       satisfy the domain requirement — but it folds two situations an operator repairs
       differently into one word:

         after = before   the context could not be reduced further
         after > before   the summarizer produced a LARGER context than it was given

       The second is the summarizer working against itself and is worth seeing on its
       own; the first is a property of the input. Naming them keeps the terminal's
       slot_id / call_id / plan fingerprint, which a flat rejection would have dropped
       (keeper_post_turn.ml maps the two shapes to different payloads). *)
    let reject_terminal cause =
      reject (terminal_rejection requested.exact_execution_evidence cause)
    in
    if after_bytes = before_bytes
    then reject_terminal Keeper_compaction_outcome.Compaction_produced_no_reduction
    else if after_bytes > before_bytes
    then reject_terminal Keeper_compaction_outcome.Compaction_increased_checkpoint
    else (
      let after_messages = message_count compacted_ctx in
      let before_tool_use_count, before_tool_result_count =
        tool_block_counts (messages_of_context ctx)
      in
      let after_tool_use_count, after_tool_result_count =
        tool_block_counts (messages_of_context compacted_ctx)
      in
      let evidence_result =
        let exact = requested.exact_execution_evidence in
        let accounting = requested.plan_accounting in
        if after_messages <> accounting.expected_after_message_count
        then
          Error
            (Keeper_compaction_evidence.Invalid_transition
               ( Keeper_compaction_evidence.Messages
               , accounting.expected_after_message_count
               , after_messages ))
        else if after_tool_use_count <> accounting.expected_after_tool_use_count
        then
          Error
            (Keeper_compaction_evidence.Invalid_transition
               ( Keeper_compaction_evidence.Tool_uses
               , accounting.expected_after_tool_use_count
               , after_tool_use_count ))
        else if after_tool_result_count <> accounting.expected_after_tool_result_count
        then
          Error
            (Keeper_compaction_evidence.Invalid_transition
               ( Keeper_compaction_evidence.Tool_results
               , accounting.expected_after_tool_result_count
               , after_tool_result_count ))
        else
          Keeper_compaction_evidence.create
            ~slot_id:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_slot_id exact)
            ~call_id:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_call_id exact)
            ~target_identity_fingerprint:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_target_identity_fingerprint exact)
            ~catalog_generation_fingerprint:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_catalog_generation_fingerprint exact)
            ~catalog_evidence_sha256:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_catalog_evidence_sha256 exact)
            ~plan_fingerprint:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_plan_fingerprint exact)
            ~receipt_request_body_sha256:
              (Keeper_compaction_llm_summarizer.exact_execution_evidence_receipt_request_body_sha256 exact)
            ~before_checkpoint_bytes:before_bytes
            ~after_checkpoint_bytes:after_bytes
            ~before_message_count:before_messages
            ~after_message_count:after_messages
            ~summarized_message_count:requested.summarized_message_count
            ~dropped_message_count:requested.dropped_message_count
            ~before_tool_use_count
            ~after_tool_use_count
            ~before_tool_result_count
            ~after_tool_result_count
      in
      match evidence_result with
      | Error error ->
        let terminal =
          Keeper_compaction_llm_summarizer.exact_execution_terminal
            ~cause:Keeper_compaction_outcome.Invalid_structural_evidence
            requested.exact_execution_evidence
        in
        reject (Invalid_structural_evidence (error, terminal))
      | Ok evidence ->
        let compacted_ctx = sync_agent_core_context compacted_ctx in
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
                ])
          (Printf.sprintf
             "context compaction prepared keeper=%s saved_checkpoint_bytes=%d"
             meta.name
             (before_bytes - after_bytes));
        { context = compacted_ctx
        ; decision = Prepared trigger
        ; evidence = Some evidence
        })
;;

let compact_for_request_typed
      ?before_dispatch_authority
      ~base_path
      ~meta
      ~trigger
      ctx
  =
  compact_for_request_typed_with
    ~requested_messages:
      (requested_messages
         ?before_dispatch_authority
         ~base_path
         meta)
    ~meta
    ~trigger
    ctx
;;

module For_testing = struct
  let compact_for_request_typed_with_accounting
        ~plan_for_units
        ?expected_after_message_count_override
        ~summarized_message_count_override
        ~meta
        ~trigger
        ctx
    =
    let requested_messages messages =
      requested_messages_with_plan ~plan_for_units messages
      |> Result.map (fun requested ->
        let plan_accounting =
          match expected_after_message_count_override with
          | None -> requested.plan_accounting
          | Some expected_after_message_count ->
            { requested.plan_accounting with expected_after_message_count }
        in
        { requested with
          summarized_message_count = summarized_message_count_override
        ; plan_accounting
        })
    in
    compact_for_request_typed_with ~requested_messages ~meta ~trigger ctx
  ;;
end
