(** Exhaustiveness guard for [blocker_class] serialization round-trip.

    Every [blocker_class] variant must survive [to_string → of_serialized_string]
    with at most one canonical string per variant.  New variants that forget the
    serialization arm will fail this test at compile time (incomplete match) or
    at run time (round-trip mismatch / duplicate string).

    @since task-626 *)

open Alcotest
module Kmc = Masc.Keeper_meta_contract
open Kmc

(* ── All variants listed exhaustively ──────────────────────────── *)

(** Canonical list of all [blocker_class] variants.  When a new variant is
    added to the type, append it here — the compiler will refuse to build if
    the match in [to_string] / [of_serialized_string] is incomplete. *)
let all_variants : blocker_class list =
  [ Runtime_exhausted (Other_detail "test")
  ; Runtime_exhausted Connection_refused
  ; Runtime_exhausted Dns_failure
  ; Runtime_exhausted No_providers_available
  ; Runtime_exhausted All_providers_failed
  ; Runtime_exhausted Candidates_filtered_after_cycles
  ; Runtime_exhausted Session_conflict
  ; Runtime_exhausted Capacity_exhausted
  ; Capacity_backpressure
  ; Fiber_unresolved
  ; Stale_turn_timeout
  ; Stale_fleet_batch
  ; Sdk_context_window_exceeded
  ; Sdk_unrecognized_stop_reason
  ; Sdk_idle_detected
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
          (* Runtime_exhausted payloads collapse to [Other_detail] on
             deserialization — that is the expected lossy round-trip. *)
          let s' = blocker_class_to_string result in
          check string ("round-trip string for " ^ s) s s'))
    all_variants
;;

(* ── Uniqueness test ───────────────────────────────────────────── *)

(** [Runtime_exhausted] sub-variants all collapse to the same
    ["runtime_exhausted"] string — this is the intended lossy design.  We test
    uniqueness on the *canonical* strings (one per top-level variant). *)
let test_string_uniqueness () =
  let strings = List.map blocker_class_to_string all_variants in
  let rec check_unique seen = function
    | [] -> ()
    | s :: rest ->
      (* "runtime_exhausted" appears for every Runtime_exhausted sub-variant
         — skip duplicates of that specific string. *)
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

(* ── SDK error → blocker_class mapping exhaustiveness ────────────── *)

module SdkE = Agent_sdk.Error
module SdkRetry = Agent_sdk.Retry
module KSB = Masc.Keeper_status_bridge_blocker
module KTD = Masc.Keeper_turn_driver
module Reg = Masc.Keeper_registry

(** Every [Agent_sdk.Error.Agent _] sub-variant must have an explicit blocker
    decision through the two-layer pipeline in [blocker_class_of_sdk_error]:
    1. [classify_masc_internal_error] — for runtime-layer structured errors
    2. Direct SDK pattern match — for Agent sub-variants

    When a new Agent sub-variant is added to the SDK, this test forces the
    developer to decide: map it to a blocker_class or list why it is an
    observation/control checkpoint for which [None] is correct. *)

let all_sdk_agent_variants : (string * SdkE.sdk_error) list =
  [ ( "UnrecognizedStopReason"
    , SdkE.Agent (SdkE.UnrecognizedStopReason { reason = "abrupt" }) )
  ; ( "HookExecutionFailed"
    , SdkE.Agent
        (SdkE.HookExecutionFailed
           { hook_name = "post_tool_use"
           ; stage = "execute"
           ; tool_name = Some "Execute"
           ; tool_use_id = Some "tool-1"
           ; detail = "hook failed"
           }) )
  ; ( "GuardrailViolation"
    , SdkE.Agent (SdkE.GuardrailViolation { validator = "content_filter"; reason = "toxic" }) )
  ; ( "TripwireViolation"
    , SdkE.Agent (SdkE.TripwireViolation { tripwire = "disallow_shell"; reason = "exec detected" }) )
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

let agent_variants_with_no_runtime_blocker =
  [ "HookExecutionFailed" ]

let test_all_agent_variants_classified_intentionally () =
  List.iter
    (fun (label, sdk_error) ->
       let expected_none =
         List.exists (fun allowed -> String.equal allowed label)
           agent_variants_with_no_runtime_blocker
       in
       match KSB.blocker_class_of_sdk_error sdk_error, expected_none with
       | Some _, false -> ()
       | None, true -> ()
       | Some klass, true ->
         failf
           "Agent sub-variant %S unexpectedly mapped to blocker_class %S"
           label
           (blocker_class_to_string klass)
       | None, false ->
         failf
           "Agent sub-variant %S returned None from blocker_class_of_sdk_error — \
            either map it to a blocker_class or document why None is correct"
           label)
    all_sdk_agent_variants
;;

(** Pin the Agent sub-variant count so additions are visible in diffs.
    When the SDK adds a new [Agent] sub-variant, bump this number and add it
    to [all_sdk_agent_variants]. *)
let expected_agent_variant_count = 5

let test_agent_variant_count_pin () =
  let count = List.length all_sdk_agent_variants in
  check int
    "Agent sub-variant count (pin — bump when SDK adds new Agent variants)"
    expected_agent_variant_count count
;;

let test_api_timeout_prose_does_not_map_to_agent_timeout () =
  let api_timeout =
    SdkE.Api
      (SdkRetry.Timeout
         { message =
             "Turn wall-clock budget exhausted during runtime attempt \
              (budget=554.9s)"
         ; phase = Some Llm_provider.Http_client.Http_operation
         })
  in
  check (option string)
    "API timeout prose does not synthesize an agent blocker"
    None
    (KSB.blocker_class_of_sdk_error api_timeout
     |> Option.map blocker_class_to_string)
;;


(* ── Provider runtime record classification ────────────────────── *)

let provider_runtime_surface_exn
      ?(detail = "provider runtime failed")
      ~reason
      ~code
      ()
  =
  let failure_reason =
    Reg.Provider_runtime_error
      { code
      ; detail
      ; provider_id = None
      ; http_status = None
      ; runtime_id = Some "r"
      ; reason
      }
  in
  match KSB.runtime_blocker_surface_of_failure_reason failure_reason with
  | Some surface -> surface
  | None ->
    fail "runtime_blocker_surface_of_failure_reason returned None for Provider_runtime_error"
;;

let test_typed_provider_reason_falls_through () =
  let surface =
    provider_runtime_surface_exn
      ~reason:(Some Connection_refused)
      ~code:"runtime_exhausted_connection_refused"
      ()
  in
  check string
    "non-NTC provider error -> provider_runtime_error catch-all"
    "provider_runtime_error"
    surface.KSB.blocker_class
;;

let test_reason_none_provider_error_falls_through () =
  let surface =
    provider_runtime_surface_exn ~reason:None ~code:"provider_error"
      ()
  in
  check string
    "reason=None provider error -> provider_runtime_error catch-all"
    "provider_runtime_error"
    surface.KSB.blocker_class
;;

let test_provider_timeout_catch_all_stays_provider_runtime_error () =
  let surface =
    provider_runtime_surface_exn
      ~reason:None
      ~code:"provider_error_timeout:http_operation"
      ~detail:
        "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
      ()
  in
  check string
    "provider timeout catch-all remains provider_runtime_error"
    "provider_runtime_error"
    surface.KSB.blocker_class
;;

let test_provider_timeout_detail_without_code_does_not_map_to_turn_timeout () =
  let surface =
    provider_runtime_surface_exn
      ~reason:None
      ~code:"provider_error"
      ~detail:
        "Provider 'unknown' timeout phase=http_operation: HTTP operation exceeded wall-clock timeout"
      ()
  in
  check
    string
    "detail-only timeout text is not trusted"
    "provider_runtime_error"
    surface.KSB.blocker_class
;;

let test_masc_accept_rejected_provider_record_does_not_reparse_detail () =
  let accept_error =
    KTD.sdk_error_of_masc_internal_error
      (KTD.Accept_rejected
         { scope = "runpod_fable5.gemma4-coder-fable5"
         ; model = Some "runtime"
         ; reason_kind = Some KTD.Accept_no_usable_progress
         ; response_shape = Some KTD.Accept_response_empty
         ; stop_reason = None
         ; reason = "shape=empty; stop_reason=end_turn"
         })
  in
  let surface =
    provider_runtime_surface_exn
      ~reason:None
      ~code:"accept_rejected"
      ~detail:(Agent_sdk.Error.to_string accept_error)
      ()
  in
  check string
    "provider runtime detail is not reparsed"
    "provider_runtime_error"
    surface.KSB.blocker_class
;;

(* ── Runner ────────────────────────────────────────────────────── *)

let () =
  Alcotest.run
    "blocker_class_exhaustiveness"
    [ ( "serialization"
      , [ test_case "round-trip" `Quick test_roundtrip
        ; test_case "string uniqueness" `Quick test_string_uniqueness
        ; test_case "unknown string returns None" `Quick test_unknown_string
        ] )
    ; ( "sdk_error_mapping"
      , [ test_case "all Agent variants are intentionally classified" `Quick
            test_all_agent_variants_classified_intentionally
        ; test_case "Agent variant count pin" `Quick test_agent_variant_count_pin
        ; test_case "API timeout prose does not synthesize agent timeout" `Quick
            test_api_timeout_prose_does_not_map_to_agent_timeout
        ] )
    ; ( "provider_runtime_record"
      , [ test_case "typed reason falls through" `Quick
            test_typed_provider_reason_falls_through
        ; test_case "reason=None provider error falls through" `Quick
            test_reason_none_provider_error_falls_through
        ; test_case "provider timeout catch-all stays provider runtime" `Quick
            test_provider_timeout_catch_all_stays_provider_runtime_error
        ; test_case
            "provider timeout detail without code stays provider runtime"
            `Quick
            test_provider_timeout_detail_without_code_does_not_map_to_turn_timeout
        ; test_case "provider runtime detail is not reparsed" `Quick
            test_masc_accept_rejected_provider_record_does_not_reparse_detail
        ] )
    ]
;;
