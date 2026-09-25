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
  ; Provider_capacity
  ; Fiber_unresolved
  ; Agent_core_context_window_exceeded
  ; Agent_core_unrecognized_stop_reason
  ; Agent_core_guardrail_violation
  ; Agent_core_tripwire_violation
  ; Agent_core_input_required
  ; Internal_unhandled_exception
  ; Internal_bridge_exception
  ; Internal_contract_rejected
  ; Incomplete_tool_transcript
  ; Terminal_effect_failed
  ; Provider_attempt_effect_fenced
  ; Tool_correction_lost
  ; Receipt_persistence_failed
  ; Gate_replay_repair_required
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

module KSB = Masc.Keeper_status_bridge_blocker
module KTD = Masc.Keeper_turn_driver
module Reg = Masc.Keeper_registry

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
      ; agent_core_timeout = None
      ; reason
      }
  in
  match (KSB.runtime_blocker_surface_of_failure_reason
      ~latest_receipt:(fun () -> Masc.Keeper_execution_receipt.No_receipt)) failure_reason with
  | Some surface -> surface
  | None ->
    fail "runtime_blocker_surface_of_failure_reason returned None for Provider_runtime_error"
;;

(* This used to assert the fall-through: a Provider_runtime_error carrying a
   typed exhaustion reason still came out labelled "provider_runtime_error",
   even with a code that spelled the exhaustion out. That is what made the
   status bridge's runtime_exhausted arm unreachable (#30447) — the registry
   wraps exhaustion in this constructor and the reason was being dropped. *)
let test_typed_provider_reason_reaches_runtime_exhausted () =
  let surface =
    provider_runtime_surface_exn
      ~reason:(Some Connection_refused)
      ~code:"runtime_exhausted_connection_refused"
      ()
  in
  check string
    "a typed exhaustion reason is not flattened into the provider catch-all"
    "runtime_exhausted"
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

(* A typed provider code that is not a timeout: the summary carries the
   record's own code and detail and nothing else. It used to call the record
   a catch-all and send the operator to find a typed cause the code already
   named (msx-retro-mania, 2026-09-22: a repeated-generation stop the lane
   had already moved past). *)
let test_typed_provider_code_summary_is_the_record () =
  let code = "provider_error_repeating_generation:repeated_reasoning_cycle" in
  let detail =
    "Provider 'ollama_cloud' model repeated itself (repeated_reasoning_cycle: one \
     270-byte unit 4 times); the stream was ended and the next candidate must be a \
     different model"
  in
  let surface = provider_runtime_surface_exn ~reason:None ~code ~detail () in
  check string "class" "provider_runtime_error" surface.KSB.blocker_class;
  check string "the summary is the record's code and detail"
    (Printf.sprintf "Provider runtime error (%s): %s" code detail)
    (Lazy.force surface.KSB.summary)
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
    KTD.core_error_of_masc_internal_error
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
      ~detail:(Agent_core.Error.to_string accept_error)
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
    ; ( "provider_runtime_record"
      , [ test_case "typed reason reaches runtime_exhausted" `Quick
            test_typed_provider_reason_reaches_runtime_exhausted
        ; test_case "reason=None provider error falls through" `Quick
            test_reason_none_provider_error_falls_through
        ; test_case "a typed provider code is summarised as its own record" `Quick
            test_typed_provider_code_summary_is_the_record
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
