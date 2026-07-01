open Alcotest

module EC = Masc.Keeper_error_classify
module UT = Masc.Keeper_unified_turn
module KP = Keeper_state_machine

let keeper_name = "test-keeper"

(* context_overflow_limit is now in OAS as Retry.extract_context_limit.
   These tests verify the OAS SSOT API is accessible from MASC. *)
let test_context_overflow_limit_parses_common_oas_errors () =
  check
    (option int)
    "available context size extracted"
    (Some 159671)
    (Agent_sdk.Retry.extract_context_limit
       "OpenAI returned 400: This model's maximum context length is 128000 tokens. \
        However, your messages resulted in 193217 tokens. available context size \
        (159671)");
  check
    (option int)
    "input budget exceeded extracted"
    (Some 8192)
    (Agent_sdk.Retry.extract_context_limit
       "Agent run failed: Input token budget exceeded:\n  10847/8192");
  check
    (option int)
    "non-overflow message"
    None
    (Agent_sdk.Retry.extract_context_limit "HTTP error: 503 Service Unavailable")
;;

let test_is_context_overflow_only_for_overflow_errors () =
  check
    bool
    "ContextOverflow matches"
    true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check
    bool
    "ContextOverflow without limit"
    true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "NetworkError does not match"
    false
    (EC.is_context_overflow
       (Agent_sdk.Error.Api
          (NetworkError
             { message = "Connection_reset"
             ; kind = Llm_provider.Http_client.Connection_refused
             })));
  check
    bool
    "Internal does not match"
    false
    (EC.is_context_overflow (Agent_sdk.Error.Internal "some error"))
;;

(* Regression: ContextOverflow used to fall through to the generic
   turn_consecutive_failures counter (no auto-recovery, escalates to a hard
   Keeper_fiber_crash after keeper_max_turn_failures). Now that the retry
   loop (keeper_unified_turn_execution.ml) drives
   Keeper_turn_runtime_budget.pause_keeper_for_overflow at the point of
   detection — the Overflowed/Compacting FSM's retry-exhausted path,
   auto-resume-with-backoff — this error must be classified as
   auto-recoverable so [record_failure_and_maybe_escalate] does not also
   count it toward that same crash threshold. *)
let test_context_overflow_is_auto_recoverable () =
  check
    bool
    "ContextOverflow is auto-recoverable at turn level (handled by \
     pause_keeper_for_overflow, not the generic crash counter)"
    true
    (EC.is_auto_recoverable_turn_error
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })))
;;

let test_summarize_turn_event_bus_extracts_overflow_signal () =
  let events =
    [ Agent_sdk.Event_bus.mk_event
        ~correlation_id:"cid-123"
        ~run_id:"run-1"
        (Agent_sdk.Event_bus.TurnStarted { agent_name = keeper_name; turn = 1 })
    ; Agent_sdk.Event_bus.mk_event
        ~correlation_id:"cid-123"
        ~run_id:"run-1"
        (Agent_sdk.Event_bus.ContextOverflowImminent
           { agent_name = keeper_name
           ; estimated_tokens = 205_000
           ; limit_tokens = 200_000
           ; ratio = 1.025
           })
    ]
  in
  let summary = UT.summarize_turn_event_bus events in
  check int "event count" 2 summary.event_count;
  check
    (list string)
    "payload kinds"
    [ "turn_started"; "context_overflow_imminent" ]
    summary.payload_kinds;
  check
    (option string)
    "correlation id from first event"
    (Some "cid-123")
    summary.correlation_id;
  check (option string) "run id from first event" (Some "run-1") summary.run_id;
  check int "no compact started" 0 summary.context_compact_started_count;
  check int "no compacted" 0 summary.context_compacted_count;
  match summary.overflow_imminent with
  | Some overflow ->
    check int "estimated tokens" 205_000 overflow.estimated_tokens;
    check int "limit tokens" 200_000 overflow.limit_tokens
  | None -> fail "expected overflow_imminent summary"
;;

let test_summarize_turn_event_bus_extracts_compaction_signal () =
  let events =
    [ Agent_sdk.Event_bus.mk_event
        ~correlation_id:"cid-compact"
        ~run_id:"run-compact-start"
        ~caused_by:"parent-run"
        (Agent_sdk.Event_bus.ContextCompactStarted
           { agent_name = keeper_name; trigger = "proactive" })
    ; Agent_sdk.Event_bus.mk_event
        ~correlation_id:"cid-compact"
        ~run_id:"run-compact-done"
        (Agent_sdk.Event_bus.ContextCompacted
           { agent_name = keeper_name
           ; before_tokens = 210_000
           ; after_tokens = 120_000
           ; phase = "proactive(85%)"
           })
    ]
  in
  let summary = UT.summarize_turn_event_bus events in
  check int "compaction event count" 2 summary.event_count;
  check
    (list string)
    "compaction payload kinds"
    [ "context_compact_started"; "context_compacted" ]
    summary.payload_kinds;
  check
    (option string)
    "compaction correlation"
    (Some "cid-compact")
    summary.correlation_id;
  check (option string) "compaction first run id" (Some "run-compact-start") summary.run_id;
  check (option string) "compaction caused_by" (Some "parent-run") summary.caused_by;
  check int "compact started count" 1 summary.context_compact_started_count;
  check int "compacted count" 1 summary.context_compacted_count;
  match summary.last_compaction with
  | Some compaction ->
    check int "before tokens" 210_000 compaction.before_tokens;
    check int "after tokens" 120_000 compaction.after_tokens;
    check int "tokens freed" 90_000 compaction.tokens_freed;
    check string "phase hint" "proactive(85%)" compaction.phase_hint
  | None -> fail "expected last compaction summary"
;;

let test_context_overflow_event_prefers_event_bus_signal () =
  let turn_event_bus : UT.turn_event_bus_summary =
    { correlation_id = Some "cid-123"
    ; run_id = Some "run-1"
    ; caused_by = None
    ; event_count = 1
    ; payload_kinds = [ "context_overflow_imminent" ]
    ; overflow_imminent = Some { estimated_tokens = 205_000; limit_tokens = 200_000 }
    ; context_compact_started_count = 0
    ; context_compacted_count = 0
    ; last_compaction = None
    }
  in
  match
    UT.context_overflow_event_of_error
      ~fallback_tokens:32_768
      ~turn_event_bus
      (Agent_sdk.Error.Api
         (ContextOverflow { message = "prompt exceeds context"; limit = Some 32_768 }))
  with
  | KP.Context_overflow_detected
      { source = `Oas_signal; token_count; limit_tokens = Some limit_tokens } ->
    check int "estimated tokens win" 205_000 token_count;
    check int "event bus limit wins" 200_000 limit_tokens
  | event -> fail ("expected oas_signal overflow event, got " ^ KP.event_to_string event)
;;

let test_context_overflow_event_falls_back_without_event_bus_signal () =
  match
    UT.context_overflow_event_of_error
      ~fallback_tokens:32_768
      (Agent_sdk.Error.Api
         (ContextOverflow { message = "prompt exceeds context"; limit = Some 32_768 }))
  with
  | KP.Context_overflow_detected
      { source = `Prompt_rejected; token_count; limit_tokens = Some limit_tokens } ->
    check int "fallback uses error limit" 32_768 token_count;
    check int "fallback preserves limit" 32_768 limit_tokens
  | event ->
    fail ("expected prompt_rejected overflow event, got " ^ KP.event_to_string event)
;;

let () =
  run
    "keeper_unified_context_overflow"
    [ ( "context_overflow"
      , [ test_case
            "parses common OAS overflow errors (SSOT)"
            `Quick
            test_context_overflow_limit_parses_common_oas_errors
        ; test_case
            "is_context_overflow only matches ContextOverflow"
            `Quick
            test_is_context_overflow_only_for_overflow_errors
        ; test_case
            "context overflow is auto-recoverable (handled by \
             pause_keeper_for_overflow)"
            `Quick
            test_context_overflow_is_auto_recoverable
        ; test_case
            "summarize_turn_event_bus extracts overflow signal"
            `Quick
            test_summarize_turn_event_bus_extracts_overflow_signal
        ; test_case
            "summarize_turn_event_bus extracts compaction signal"
            `Quick
            test_summarize_turn_event_bus_extracts_compaction_signal
        ; test_case
            "context_overflow_event prefers event bus signal"
            `Quick
            test_context_overflow_event_prefers_event_bus_signal
        ; test_case
            "context_overflow_event falls back without event bus signal"
            `Quick
            test_context_overflow_event_falls_back_without_event_bus_signal
        ] )
    ]
;;
