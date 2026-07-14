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

type compaction_decision =
  | Applied of Compaction_trigger.t
  | Prepared of Compaction_trigger.t
  | Rejected of Compaction_trigger.t * compaction_rejection
  | Not_requested
  | Skipped_no_checkpoint

and compaction_rejection =
  | Retired_deterministic_mode
  | Runtime_unavailable
  | Summarizer_unavailable_or_invalid
  | Structural_noop

let compaction_rejection_to_string = function
  | Retired_deterministic_mode -> "retired_deterministic_mode"
  | Runtime_unavailable -> "runtime_unavailable"
  | Summarizer_unavailable_or_invalid -> "summarizer_unavailable_or_invalid"
  | Structural_noop -> "structural_noop"

let compaction_decision_to_string = function
  | Applied trigger -> "applied:" ^ Compaction_trigger.to_human trigger
  | Prepared trigger -> "prepared:" ^ Compaction_trigger.to_human trigger
  | Rejected (trigger, reason) ->
    Printf.sprintf "rejected:%s:%s"
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

let serialize_messages messages =
  Yojson.Safe.to_string (`List (List.map message_to_json messages))
;;

let compact_for_request_typed
      ~(meta : keeper_meta)
      ~(trigger : Compaction_trigger.t)
      (ctx : working_context)
  : working_context * Compaction_trigger.t option * compaction_decision
  =
  let source_messages = messages_of_context ctx in
  let reject reason detail =
    Log.Keeper.warn ~keeper_name:meta.name "context compaction rejected: %s" detail;
    Error reason
  in
  let candidate =
    match meta.compaction.mode with
    | Keeper_config.Deterministic ->
      reject Retired_deterministic_mode "deterministic reducer is retired"
    | Keeper_config.Llm ->
      let runtime_id =
        try
          let id = Keeper_meta_contract.runtime_id_of_meta meta |> String.trim in
          if id = "" then reject Runtime_unavailable "runtime identity is empty"
          else Ok id
        with
        | Failure detail -> reject Runtime_unavailable detail
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
          | None ->
            reject
              Summarizer_unavailable_or_invalid
              "configured summarizer is unavailable"
          | Some summarize ->
            (match summarize ~messages:source_messages with
             | None ->
               reject
                 Summarizer_unavailable_or_invalid
                 "no valid semantic compaction plan"
             | Some plan ->
               Ok
                 (Keeper_compaction_llm_summarizer.apply
                    plan
                    ~messages:source_messages))))
  in
  match candidate with
  | Error reason -> ctx, None, Rejected (trigger, reason)
  | Ok candidate ->
    let messages, pair_repair_stats =
      Keeper_context_core.repair_broken_tool_call_pairs_with_stats candidate
    in
    let compacted_ctx =
      sync_oas_context
        { ctx with checkpoint = { (checkpoint_of_context ctx) with messages } }
    in
    let before_json = serialize_messages source_messages in
    let after_json = serialize_messages messages in
    if String.equal before_json after_json
    then (
      Log.Keeper.warn
        ~keeper_name:meta.name
        "context compaction rejected: plan produced no structural checkpoint change";
      ctx, None, Rejected (trigger, Structural_noop))
    else (
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
            ; "trigger", Compaction_trigger.to_detail_json trigger
            ; "before_messages", `Int (List.length source_messages)
            ; "after_messages", `Int (List.length messages)
            ; "before_checkpoint_bytes", `Int (String.length before_json)
            ; "after_checkpoint_bytes", `Int (String.length after_json)
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
      (Printf.sprintf "context compaction prepared keeper=%s" meta.name);
    compacted_ctx, Some trigger, Prepared trigger)
;;
