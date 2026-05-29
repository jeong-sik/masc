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
  [ Cascade_exhausted No_tool_capable
  ; Cascade_exhausted (Other_detail "test")
  ; Cascade_exhausted Connection_refused
  ; Cascade_exhausted Dns_failure
  ; Cascade_exhausted No_providers_available
  ; Cascade_exhausted All_providers_failed
  ; Cascade_exhausted Candidates_filtered_after_cycles
  ; Cascade_exhausted Max_turns_exceeded
  ; Cascade_exhausted (Structural_attempt_timeout { detail = "30" })
  ; Cascade_exhausted Capacity_exhausted
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
          (* Cascade_exhausted with non-No_tool_capable payloads all collapse
             to [Other_detail] on deserialization — that is the expected
             lossy round-trip.  Only [No_tool_capable] must be exact. *)
          let s' = blocker_class_to_string result in
          check string ("round-trip string for " ^ s) s s'))
    all_variants
;;

(* ── No_tool_capable specific test ─────────────────────────────── *)

let test_no_tool_capable_mapping () =
  let s = blocker_class_to_string (Cascade_exhausted No_tool_capable) in
  check string "No_tool_capable serializes correctly" "cascade_exhausted_no_tool_capable" s;
  match blocker_class_of_serialized_string "cascade_exhausted_no_tool_capable" with
  | None -> fail "deserialization of cascade_exhausted_no_tool_capable returned None"
  | Some (Cascade_exhausted No_tool_capable) -> ()
  | Some other ->
    let s' = blocker_class_to_string other in
    failf "expected Cascade_exhausted No_tool_capable, got %S" s'
;;

(* ── Uniqueness test ───────────────────────────────────────────── *)

(** [Cascade_exhausted] sub-variants (except [No_tool_capable]) all collapse to
    the same ["cascade_exhausted"] string — this is the intended lossy design.
    We test uniqueness on the *canonical* strings (one per top-level variant). *)
let test_string_uniqueness () =
  let strings = List.map blocker_class_to_string all_variants in
  let rec check_unique seen = function
    | [] -> ()
    | s :: rest ->
      (* "cascade_exhausted" appears for every Cascade_exhausted sub-variant
         except No_tool_capable — skip duplicates of that specific string. *)
      if s = "cascade_exhausted" then check_unique seen rest
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
    ]
;;
