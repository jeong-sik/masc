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
  | Runtime_identity_unavailable
  | Summarizer_unavailable
  | Plan_provider_unavailable
  | Invalid_compaction_plan
  | Invalid_structure of Keeper_compaction_unit.structural_error
  | No_eligible_history
  | Structurally_unchanged
  | Checkpoint_not_reduced
  | Invalid_structural_evidence of Keeper_compaction_evidence.decode_error

let compaction_rejection_to_tag = function
  | Runtime_identity_unavailable -> "runtime_identity_unavailable"
  | Summarizer_unavailable -> "summarizer_unavailable"
  | Plan_provider_unavailable -> "plan_provider_unavailable"
  | Invalid_compaction_plan -> "invalid_compaction_plan"
  | Invalid_structure error ->
    "invalid_structure:" ^ Keeper_compaction_unit.show_structural_error error
  | No_eligible_history -> "no_eligible_history"
  | Structurally_unchanged -> "structurally_unchanged"
  | Checkpoint_not_reduced -> "checkpoint_not_reduced"
  | Invalid_structural_evidence _ -> "invalid_structural_evidence"
;;

let compaction_rejection_to_string = function
  | Invalid_structural_evidence error ->
    compaction_rejection_to_tag (Invalid_structural_evidence error)
    ^ ":"
    ^ Keeper_compaction_evidence.decode_error_to_string error
  | reason -> compaction_rejection_to_tag reason
;;

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
  ; selected_runtime_id : string
  ; summarized_message_count : int
  ; dropped_message_count : int
  }

type compaction_runtime_source =
  | Structured_judge
  | Keeper_chat

let compaction_runtime_source_to_label = function
  | Structured_judge -> "structured_judge"
  | Keeper_chat -> "keeper_chat"

(* Exact non-blank runtime id from a lazily-invoked source. Whitespace is used
   only to reject a blank value; the configured identity is never normalized.
   Legacy [Failure] results remain unavailable, but are never silent. [f] must
   be a thunk because OCaml evaluates ordinary arguments before the call. *)
let runtime_id_opt ~keeper_name ~source (f : unit -> string) =
  match f () with
  | runtime_id ->
    if String.trim runtime_id = ""
    then (
      Log.Keeper.warn ~keeper_name
        "compaction runtime source is blank source=%s"
        (compaction_runtime_source_to_label source);
      None)
    else Some runtime_id
  | exception Failure detail ->
    Log.Keeper.warn ~keeper_name
      "compaction runtime source unavailable source=%s: %s"
      (compaction_runtime_source_to_label source)
      detail;
    None
;;

(* The structured-judge lane is schema-capable by construction (RFC-0307):
   every consumer that needs provider-native structured output (board
   attention judgment, failure judgment, HITL summary) routes there instead of
   inheriting a keeper's own chat assignment. Compaction used to be the one
   exception, sourcing its runtime solely from the keeper's chat assignment
   ([Keeper_meta_contract.runtime_id_of_meta]) — which, for most of the fleet,
   resolves to [runtime].default. That default is picked for chat throughput,
   not schema support, so schema-ineligible chat models (e.g.
   deepseek-v4-flash) left compaction permanently rejecting with
   [Summarizer_unavailable]: those keepers could never compact, so their
   history only grew until every turn hit a provider ContextOverflow (#25051).

   Trying the structured-judge id first fixes that without weakening the
   fail-closed schema check in
   [Keeper_compaction_llm_summarizer.eligible_candidate]: it is just a
   higher-priority *candidate*, still filtered for schema support like any
   other. The keeper's own chat runtime stays as a later candidate — sound
   only because that per-candidate schema filter still applies to it, so an
   already-eligible chat model (or an operator-configured compaction lane) is
   never displaced. *)
let compaction_runtime_ids (meta : keeper_meta) =
  List.filter_map
    Fun.id
    [ runtime_id_opt
        ~keeper_name:meta.name
        ~source:Structured_judge
        Runtime.runtime_id_for_structured_judge
    ; runtime_id_opt
        ~keeper_name:meta.name
        ~source:Keeper_chat
        (fun () -> Keeper_meta_contract.runtime_id_of_meta meta)
    ]
;;

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
let requested_messages (meta : keeper_meta) messages =
  match Keeper_compaction_unit.partition ~quarantine:true messages with
  | Error error -> Error (Invalid_structure error)
  | Ok { closed_prefix = []; _ } -> Error No_eligible_history
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

       The observable outcome is deliberately NOT identical to the late
       failure, and the difference is the point:

       - Late: [commit_prepared_compaction] returns [Error], which
         [Keeper_manual_compaction.run_commit] folds into its catch-all
         [Error (Recovery _)] -> [Manual_compaction_failed] -> [Requeue
         Context_compaction_retry]. That settlement is not an ack
         (keeper_heartbeat_loop.ml), so the same doomed request is re-driven
         every cycle — one summarizer call each time. This is the live
         livelock: 102 failures and 104 compaction LLM calls in the 74 minutes
         after the #25413 build went live.
       - Early: the typed [No_compaction] arm of
         [Keeper_manual_compaction.finish_preparation] acks and settles
         terminally, with a ledger row and a [compaction_rejected] log line.

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
    if not (Keeper_compaction_llm_summarizer.has_eligible_units units)
    then Error No_eligible_history
    else
      (match compaction_runtime_ids meta with
       | [] -> Error Runtime_identity_unavailable
       | runtime_ids ->
         (match
            Keeper_compaction_llm_summarizer.make
              ~runtime_ids
              ~keeper_name:meta.name
              ()
          with
          | None -> Error Summarizer_unavailable
          | Some summarize ->
            (match summarize ~units with
             | Error Keeper_compaction_llm_summarizer.Provider_unavailable ->
               Error Plan_provider_unavailable
             | Error Keeper_compaction_llm_summarizer.Invalid_plan ->
               Error Invalid_compaction_plan
             | Ok plan ->
               if not (Keeper_compaction_llm_summarizer.has_changes plan)
               then Error Structurally_unchanged
               else
                 Ok
                   { messages =
                       Keeper_compaction_llm_summarizer.apply plan
                       @ protected_suffix
                   ; selected_runtime_id =
                       Keeper_compaction_llm_summarizer.selected_runtime_id plan
                   ; summarized_message_count =
                       selected_message_count
                         units
                         (Keeper_compaction_llm_summarizer.summarized_indices plan)
                   ; dropped_message_count =
                       selected_message_count
                         units
                         (Keeper_compaction_llm_summarizer.dropped_indices plan)
                   }))))
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
    ~strategies:strategy_names
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
    let checkpoint =
      { (checkpoint_of_context ctx) with messages = requested.messages }
    in
    let compacted_ctx =
      sync_oas_context { checkpoint }
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
      match
        Keeper_compaction_evidence.create
          ~selected_runtime_id:requested.selected_runtime_id
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
      with
      | Error error -> reject (Invalid_structural_evidence error)
      | Ok evidence ->
        let compacted_ctx = sync_oas_context compacted_ctx in
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

module For_testing = struct
  let compaction_runtime_ids = compaction_runtime_ids
end
