(** Exhaustiveness guard for [blocker_class] serialization round-trip.

    Every [blocker_class] variant must survive [to_string → of_serialized_string]
    with at most one canonical string per variant.  New variants that forget the
    serialization arm will fail this test at compile time (incomplete match) or
    at run time (round-trip mismatch / duplicate string).

    @since task-626 *)

open Alcotest
module Kmc = Masc_mcp.Keeper_meta_contract
open Kmc

(* ── All variants listed exhaustively ──────────────────────────── *)

(** Canonical list of all [blocker_class] variants.  When a new variant is
    added to the type, append it here — the compiler will refuse to build if
    the match in [to_string] / [of_serialized_string] is incomplete. *)
let all_variants : blocker_class list =
  [ Runtime_exhausted (No_tool_capable None)
  ; Runtime_exhausted (Other_detail "test")
  ; Runtime_exhausted Connection_refused
  ; Runtime_exhausted Dns_failure
  ; Runtime_exhausted No_providers_available
  ; Runtime_exhausted All_providers_failed
  ; Runtime_exhausted Candidates_filtered_after_cycles
  ; Runtime_exhausted Max_turns_exceeded
  ; Runtime_exhausted (Structural_attempt_timeout { detail = "30" })
  ; Runtime_exhausted Capacity_exhausted
  ; Capacity_backpressure
  ; Ambiguous_post_commit_timeout
  ; Ambiguous_post_commit_failure
  ; Autonomous_slot_wait_timeout
  ; Admission_queue_wait_timeout
  ; Turn_timeout_after_queue_wait
  ; Turn_timeout
  ; Turn_livelock_blocked
  ; Completion_contract_violation
  ; Stay_silent_loop
  ; Fiber_unresolved
  ; Stale_turn_timeout
  ; Stale_fleet_batch
  ; Oas_agent_execution_timeout
  ; Sdk_max_turns_exceeded
  ; Sdk_token_budget_exceeded
  ; Sdk_cost_budget_exceeded
  ; Sdk_unrecognized_stop_reason
  ; Sdk_idle_detected
  ; Sdk_tool_retry_exhausted
  ; Sdk_guardrail_violation
  ; Sdk_tripwire_violation
  ; Sdk_exit_condition_met
  ; Sdk_input_required
  ]
;;

(* ── Round-trip test ───────────────────────────────────────────── *)

let test_roundtrip () =
  List.iter
    (fun variant ->
       let s = blocker_class_to_string variant in
       let deserialized = blocker_class_of_serialized_string s in
       (match deserialized with
        | None ->
          failf
            "blocker_class_of_serialized_string returned None for %S (from variant)"
            s
        | Some result ->
          (* Runtime_exhausted with non-No_tool_capable payloads all collapse
             to [Other_detail] on deserialization — that is the expected
             lossy round-trip.  Only [No_tool_capable] must be exact. *)
          let s' = blocker_class_to_string result in
          check string ("round-trip string for " ^ s) s s'))
    all_variants
;;

(* ── No_tool_capable specific test ─────────────────────────────── *)

let test_no_tool_capable_mapping () =
  let s = blocker_class_to_string (Runtime_exhausted (No_tool_capable None)) in
  check string "No_tool_capable serializes correctly" "runtime_exhausted_no_tool_capable" s;
  match blocker_class_of_serialized_string "runtime_exhausted_no_tool_capable" with
  | None -> fail "deserialization of runtime_exhausted_no_tool_capable returned None"
  | Some (Runtime_exhausted (No_tool_capable None)) -> ()
  | Some other ->
    let s' = blocker_class_to_string other in
    failf "expected Runtime_exhausted No_tool_capable, got %S" s'
;;

(* ── Uniqueness test ───────────────────────────────────────────── *)

(** [Runtime_exhausted] sub-variants (except [No_tool_capable]) all collapse to
    the same ["runtime_exhausted"] string — this is the intended lossy design.
    We test uniqueness on the *canonical* strings (one per top-level variant). *)
let test_string_uniqueness () =
  let strings = List.map blocker_class_to_string all_variants in
  let rec check_unique seen = function
    | [] -> ()
    | s :: rest ->
      (* "runtime_exhausted" appears for every Runtime_exhausted sub-variant
         except No_tool_capable — skip duplicates of that specific string. *)
      if s = "runtime_exhausted" then check_unique seen rest
      else if List.mem s seen
      then failf "duplicate blocker_class string: %S" s
      else check_unique (s :: seen) rest
  in
  check_unique [] strings
;;

(* ── Unknown string returns None ───────────────────────────────── *)

let test_unknown_string () =
  let result = blocker_class_of_serialized_string "nonexistent_blocker_class" in
  match result with
  | None -> ()
  | Some _ -> fail "expected None for unknown string"
;;

(* ── Variant count pin ─────────────────────────────────────────── *)

(** Pin the variant count so additions are visible in diffs.  When adding a
    new [blocker_class] variant, bump this number and add the variant to
    [all_variants]. *)
let expected_variant_count = 34

let test_variant_count () =
  let count = List.length all_variants in
  check int "blocker_class variant count" expected_variant_count count
;;

(* ── SDK error → blocker_class mapping exhaustiveness ────────────── *)

module SdkE = Agent_sdk.Error
module SdkRetry = Agent_sdk.Retry
module KSB = Masc_mcp.Keeper_status_bridge_blocker

(** Every [Agent_sdk.Error.Agent _] sub-variant must map to a [Some blocker_class]
    through the two-layer pipeline in [blocker_class_of_sdk_error]:
    1. [classify_masc_internal_error] — for runtime-layer structured errors
    2. Direct SDK pattern match — for Agent sub-variants

    When a new Agent sub-variant is added to the SDK, this test forces the
    developer to decide: map it to a blocker_class or explicitly document why
    [None] is correct. *)

let all_sdk_agent_variants : (string * SdkE.sdk_error) list =
  [ ( "CompletionContractViolation"
    , SdkE.Agent
        (SdkE.CompletionContractViolation
           { contract = Agent_sdk.Completion_contract_id.Require_tool_use
           ; reason = "test"
           ; violation_detail = None
           }) )
  ; ( "AgentExecutionTimeout"
    , SdkE.Agent
        (SdkE.AgentExecutionTimeout
           { elapsed_sec = 10.0; timeout_sec = 5.0; turn_count = 3; max_turns = 10 })
    )
  ; ( "MaxTurnsExceeded"
    , SdkE.Agent (SdkE.MaxTurnsExceeded { turns = 10; limit = 10 }) )
  ; ( "TokenBudgetExceeded"
    , SdkE.Agent (SdkE.TokenBudgetExceeded { kind = "token"; used = 4096; limit = 4096 }) )
  ; ( "CostBudgetExceeded"
    , SdkE.Agent (SdkE.CostBudgetExceeded { spent_usd = 0.42; limit_usd = 0.40 }) )
  ; ( "CostBudgetUnenforceable"
    , SdkE.Agent (SdkE.CostBudgetUnenforceable { model_id = "m"; limit_usd = 0.40 }) )
  ; ( "UnrecognizedStopReason"
    , SdkE.Agent (SdkE.UnrecognizedStopReason { reason = "abrupt" }) )
  ; ( "IdleDetected"
    , SdkE.Agent (SdkE.IdleDetected { consecutive_idle_turns = 3 }) )
  ; ( "ToolRetryExhausted"
    , SdkE.Agent (SdkE.ToolRetryExhausted { attempts = 3; limit = 3; detail = "rate limited" }) )
  ; ( "GuardrailViolation"
    , SdkE.Agent (SdkE.GuardrailViolation { validator = "content_filter"; reason = "toxic" }) )
  ; ( "TripwireViolation"
    , SdkE.Agent (SdkE.TripwireViolation { tripwire = "disallow_shell"; reason = "exec detected" }) )
  ; ( "ExitConditionMet"
    , SdkE.Agent (SdkE.ExitConditionMet { turn = 5 }) )
  ; ( "InputRequired"
    , SdkE.Agent
        (SdkE.InputRequired
           { request_id = "req-1"
           ; participant_name = Some "user"
           ; question = "What should I do?"
           ; schema = None
           ; timeout_s = None
           ; created_at = 0.0
           }) )
  ]
;;

let test_all_agent_variants_map_to_blocker_class () =
  List.iter
    (fun (label, sdk_error) ->
       match KSB.blocker_class_of_sdk_error sdk_error with
       | Some _ -> ()
       | None ->
         failf
           "Agent sub-variant %S returned None from blocker_class_of_sdk_error — \
            either map it to a blocker_class or document why None is correct"
           label)
    all_sdk_agent_variants
;;

(** Pin the Agent sub-variant count so additions are visible in diffs.
    When the SDK adds a new [Agent] sub-variant, bump this number and add it
    to [all_sdk_agent_variants]. *)
let expected_agent_variant_count = 13

let test_agent_variant_count_pin () =
  let count = List.length all_sdk_agent_variants in
  check int
    "Agent sub-variant count (pin — bump when SDK adds new Agent variants)"
    expected_agent_variant_count count
;;

let test_structural_timeout_maps_to_oas_timeout () =
  let structural =
    SdkE.Api
      (SdkRetry.Timeout
         { message =
             "Turn wall-clock budget exhausted during runtime attempt \
              (budget=554.9s)" })
  in
  match KSB.blocker_class_of_sdk_error structural with
  | Some klass ->
    check string
      "structural timeout maps to oas_agent_execution_timeout"
      "oas_agent_execution_timeout"
      (blocker_class_to_string klass)
  | None -> fail "structural timeout should map to Some blocker_class"
;;

(* ── Runner ────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "blocker_class_exhaustiveness"
    [ ( "serialization"
      , [ test_case "round-trip" `Quick test_roundtrip
        ; test_case "no_tool_capable mapping" `Quick test_no_tool_capable_mapping
        ; test_case "string uniqueness" `Quick test_string_uniqueness
        ; test_case "unknown string returns None" `Quick test_unknown_string
        ; test_case "variant count pin" `Quick test_variant_count
        ] )
    ; ( "sdk_error_mapping"
      , [ test_case "all Agent variants map to blocker_class" `Quick
            test_all_agent_variants_map_to_blocker_class
        ; test_case "Agent variant count pin" `Quick test_agent_variant_count_pin
        ; test_case "structural timeout → oas_agent_execution_timeout" `Quick
            test_structural_timeout_maps_to_oas_timeout
        ] )
    ]
;;
