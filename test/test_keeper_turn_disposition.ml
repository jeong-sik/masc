(** RFC-0047 PR-1 invariants for [Keeper_turn_disposition]:

    1. Byte-compat: for every wire string consumed by the legacy
       [Keeper_turn_terminal.severity_of_code / summary_of_code /
       next_action_of_code], the new typed
       [Keeper_turn_disposition.severity / summary / next_action]
       must agree on severity (rendered as string), summary, and
       next_action — *after* the legacy [normalize_code] is applied
       to the input wire (since PR-2 will keep the same producer-side
       normalisation; this test isolates the *consumer-side*
       invariant). Timeout actions intentionally differ: the legacy
       [inspect_turn_timeout] action collapsed provider, admission/capacity,
       and turn liveness ownership.

    2. Round-trip: [of_wire (to_wire t) = t] for every canonical
       constructor and for [Provider_error] wrapping each runtime
       variant.

    3. Projection: [of_termination_code] is deterministic and total
       over [Keeper_turn_terminal_code.t]. *)

module D = Masc.Keeper_turn_disposition
module Code = Masc.Keeper_turn_terminal_code
module Legacy = Masc.Keeper_turn_terminal
module Registry = Masc.Keeper_registry
module Unified_types = Masc.Keeper_unified_turn_types

(* ===== Byte-compat oracle ====================================== *)
(* For every legacy wire code, build the corresponding disposition,
   then assert that the typed accessors agree with the legacy
   substring-based accessors. *)

(* Group A: canonical application codes — strict byte-compat.
   Severity / summary / next_action must match the legacy substring
   classifier exactly. *)
let canonical_app_codes : (string * D.t) list =
  [ "success", D.Success
  ; "external_cancel", D.External_cancel
  ; "turn_wall_clock_timeout", D.Turn_wall_clock_timeout
  ; "provider_error", D.Provider_error (Code.Provider_runtime_error "provider_error")
  ; "unknown_error", D.Unknown { raw_error = "" }
  ]
;;

(* Group B: runtime-layer wire strings that legacy
   [severity_of_code] classifies via [String.starts_with ~prefix:"api_error_"]
   or via the [_ -> Unknown_bad] fallback. The legacy
   [next_action_of_code] returns [None] for these (its [_ -> None] arm),
   which is inconsistent with the legacy "provider_error" alias path
   that returns [Some "inspect_latest_error"]. RFC-0047 unifies the
   two: every [Provider_error _] disposition recommends
   [inspect_latest_error]. This is an intentional behaviour change
   documented in the RFC; only [severity] (rendered as string) is
   asserted against legacy here. *)
let runtime_wire_codes : (string * D.t) list =
  [ "api_error_overloaded", D.Provider_error (Code.Sdk_error "api_error_overloaded")
  ; "api_error_server:502", D.Provider_error (Code.Sdk_error "api_error_server:502")
  ]
;;

(* The legacy [severity] type and [D.severity] type are isomorphic; we
   compare via [severity_to_string] for ergonomics. *)
let legacy_severity_str (sev : Legacy.severity) : string = Legacy.severity_to_string sev

let typed_severity_str (sev : D.severity) : string =
  match sev with
  | D.Ok -> "ok"
  | D.Warn -> "warn"
  | D.Bad -> "bad"
  | D.Unknown_bad -> "bad"
;;

let test_canonical_severity_byte_compat () =
  List.iter
    (fun (wire, disp) ->
       let legacy = Legacy.of_code wire in
       let expected = legacy_severity_str legacy.severity in
       let actual = typed_severity_str (D.severity disp) in
       Alcotest.(check string) (Printf.sprintf "severity[%s]" wire) expected actual)
    canonical_app_codes
;;

let test_canonical_summary_byte_compat () =
  List.iter
    (fun (wire, disp) ->
       let legacy = Legacy.of_code wire in
       let expected = legacy.summary in
       let actual = D.summary disp in
       Alcotest.(check string) (Printf.sprintf "summary[%s]" wire) expected actual)
    canonical_app_codes
;;

let test_canonical_next_action_byte_compat () =
  List.iter
    (fun (wire, disp) ->
       let legacy = Legacy.of_code wire in
       let expected =
         match wire, legacy.next_action with
         | "turn_wall_clock_timeout", _ -> "Some:inspect_turn_timeout"
         | _, Some s -> "Some:" ^ s
         | _, None -> "None"
       in
       let actual =
         match D.next_action disp with
         | Some s -> "Some:" ^ s
         | None -> "None"
       in
       Alcotest.(check string) (Printf.sprintf "next_action[%s]" wire) expected actual)
    canonical_app_codes
;;

(* Runtime-wire codes: severity-only oracle. RFC-0047 §3 documents
   that [Provider_error _] uniformly recommends "inspect_latest_error"
   for next_action and uses the inner code wire as the summary suffix
   ("keeper turn ended with X"); both are intentional improvements
   over the legacy substring path. *)
let test_runtime_wire_severity_byte_compat () =
  List.iter
    (fun (wire, disp) ->
       let legacy = Legacy.of_code wire in
       let expected = legacy_severity_str legacy.severity in
       let actual = typed_severity_str (D.severity disp) in
       Alcotest.(check string) (Printf.sprintf "severity[%s]" wire) expected actual)
    runtime_wire_codes
;;

(* ===== Round-trip ============================================== *)

(* Round-trip is asymmetric:
   - [to_wire] is total (every disposition produces a string).
   - [of_wire] is best-effort. Recognised app strings round-trip.
     Recognised runtime wires (RFC-0042) round-trip via projection.
     Parametrised runtime payloads (Provider_runtime_error of string,
     Sdk_error of string, Exception_unhandled of string) and
     unrecognised legacy wires deserialise to [Unknown { raw_error }];
     no round-trip is possible without a wire-prefix scheme that
     RFC-0042 explicitly defers (§3.1 "intentionally flat"). *)
let round_trippable : (string * D.t) list =
  [ "Success", D.Success
  ; "External_cancel", D.External_cancel
  ; "Turn_wall_clock_timeout", D.Turn_wall_clock_timeout
  ; "Unknown empty", D.Unknown { raw_error = "" }
  ; "Unknown raw", D.Unknown { raw_error = "fresh_unmapped_label" }
  ; (* Runtime wires that Code.of_wire recognises losslessly (no payload
     or payload-loss is acceptable per RFC-0042 §5.2). *)
    "Provider_error/Heartbeat", D.Provider_error Code.Heartbeat_failures
  ; "Provider_error/Turn_failures", D.Provider_error Code.Turn_failures
  ; "Provider_error/Storm", D.Provider_error Code.Stale_termination_storm
  ; "Provider_error/FleetBatch", D.Provider_error Code.Stale_fleet_batch
  ; "Provider_error/TurnOverflow", D.Provider_error Code.Turn_overflow_failure
  ; "Provider_error/Fiber", D.Provider_error Code.Fiber_unresolved
  ]
;;

let test_round_trip_recognised () =
  List.iter
    (fun (label, t) ->
       let wire = D.to_wire t in
       let parsed = D.of_wire wire in
       Alcotest.(check bool)
         (label ^ " round-trip via to_wire/of_wire")
         true
         (D.equal t parsed))
    round_trippable
;;

(* Documented asymmetric cases: parametrised payloads survive serialisation
   but deserialise to [Unknown { raw_error = wire }] because the wire
   loses the constructor identity. *)
let test_round_trip_lossy_payloads () =
  let cases =
    [ ( "Provider_error/Provider_runtime payload"
      , D.Provider_error (Code.Provider_runtime_error "p_500")
      , "p_500" )
    ; ( "Provider_error/Sdk payload"
      , D.Provider_error (Code.Sdk_error "api_error_overloaded")
      , "api_error_overloaded" )
    ]
  in
  List.iter
    (fun (label, t, expected_raw) ->
       let wire = D.to_wire t in
       Alcotest.(check string) (label ^ " to_wire") expected_raw wire;
       match D.of_wire wire with
       | D.Unknown { raw_error } ->
         Alcotest.(check string)
           (label ^ " of_wire → Unknown raw_error")
           expected_raw
           raw_error
       | other -> Alcotest.failf "%s expected Unknown, got %a" label D.pp other)
    cases
;;

(* ===== Projection (of_termination_code) ======================= *)

let runtime_codes_to_projection : (string * Code.t * D.t) list =
  [ "Healthy", Code.Healthy, D.Success
  ; "Stale_turn_timeout/idle", Code.Stale_turn_timeout_idle, D.Turn_wall_clock_timeout
  ; ( "Stale_turn_timeout/in_turn"
    , Code.Stale_turn_timeout_in_turn
    , D.Turn_wall_clock_timeout )
  ; ( "Stale_turn_timeout/no_progress"
    , Code.Stale_turn_timeout_no_progress
    , D.Turn_wall_clock_timeout )
  ; "Stale_turn_timeout/noop", Code.Stale_turn_timeout_noop, D.Turn_wall_clock_timeout
  ; "Heartbeat", Code.Heartbeat_failures, D.Provider_error Code.Heartbeat_failures
  ; "Turn_failures", Code.Turn_failures, D.Provider_error Code.Turn_failures
  ; "Storm", Code.Stale_termination_storm, D.Provider_error Code.Stale_termination_storm
  ; "FleetBatch", Code.Stale_fleet_batch, D.Provider_error Code.Stale_fleet_batch
  ; "TurnOverflow", Code.Turn_overflow_failure, D.Provider_error Code.Turn_overflow_failure
  ; ( "Provider_runtime"
    , Code.Provider_runtime_error "p"
    , D.Provider_error (Code.Provider_runtime_error "p") )
  ; "Fiber", Code.Fiber_unresolved, D.Provider_error Code.Fiber_unresolved
  ; ( "Exception"
    , Code.Exception_unhandled "x"
    , D.Provider_error (Code.Exception_unhandled "x") )
  ; ( "Sdk"
    , Code.Sdk_error "api_error_server:502"
    , D.Provider_error (Code.Sdk_error "api_error_server:502") )
  ]
;;

let test_projection () =
  List.iter
    (fun (label, code, expected) ->
       let actual = D.of_termination_code code in
       Alcotest.(check bool) (label ^ " projection") true (D.equal expected actual))
    runtime_codes_to_projection
;;

let check_runtime_failure_reason raw_error expected_code =
  let terminal = Legacy.of_code raw_error in
  match Unified_types.registry_failure_reason_of_terminal_reason terminal ~raw_error with
  | Some (Registry.Provider_runtime_error { code; detail }) ->
    Alcotest.(check string) "provider runtime code" expected_code code;
    Alcotest.(check bool)
      "detail preserves structured source"
      true
      (String.contains detail '{')
  | Some other ->
    Alcotest.failf
      "expected Provider_runtime_error, got %s"
      (Registry.failure_reason_to_string other)
  | None -> Alcotest.fail "expected structured runtime failure reason"
;;

let test_registry_failure_reason_preserves_no_provider_runtime_reason () =
  let raw_error =
    "Internal error: [masc_oas_error] \
     {\"kind\":\"runtime_exhausted\",\"runtime_id\":\"runtime.strict_tool_candidates\",\
     \"reason\":\"no_providers_available\"}"
  in
  check_runtime_failure_reason
    raw_error
    "runtime_exhausted_no_providers_available"
;;

let test_registry_failure_reason_does_not_classify_free_form_detail () =
  let raw_error =
    Keeper_internal_error.sdk_error_of_masc_internal_error
      (Keeper_internal_error.Runtime_exhausted
         { runtime_id = "runtime.opaque_detail"
         ; reason =
             Keeper_internal_error.Other_detail
               "connection refused; HTTP 429; wall-clock timeout"
         })
    |> Agent_sdk.Error.to_string
  in
  check_runtime_failure_reason raw_error "runtime_exhausted_provider_failure"
;;

let empty_turn_state : Unified_types.turn_state =
  { cycle_completed = false
  ; manifest_seq = 0
  ; current_turn_blocker_info = None
  ; last_execution = None
  ; degraded_retry_info = None
  ; runtime_rotation_attempts = []
  ; failure_reason = None
  ; retry_phase_started_at = None
  }
;;

let test_missing_last_execution_is_typed_error () =
  match
    Unified_types.require_last_execution_for_finalize
      ~keeper_name:"keeper_under_test"
      empty_turn_state
  with
  | Ok _ -> Alcotest.fail "expected missing last_execution to return a typed error"
  | Error (Agent_sdk.Error.Internal message) ->
    Alcotest.(check string)
      "internal error message"
      "keeper_under_test: last_execution missing at turn finalize"
      message
  | Error err ->
    Alcotest.failf
      "expected Internal error, got %s"
      (Agent_sdk.Error.to_string err)
;;

let () =
  Alcotest.run
    "keeper_turn_disposition"
    [ ( "byte-compat oracle vs legacy keeper_turn_terminal (canonical app codes)"
      , [ Alcotest.test_case
            "severity matches legacy"
            `Quick
            test_canonical_severity_byte_compat
        ; Alcotest.test_case
            "summary matches legacy"
            `Quick
            test_canonical_summary_byte_compat
        ; Alcotest.test_case
            "next_action matches legacy"
            `Quick
            test_canonical_next_action_byte_compat
        ] )
    ; ( "byte-compat (runtime-wire codes, severity-only)"
      , [ Alcotest.test_case
            "severity matches legacy substring classifier"
            `Quick
            test_runtime_wire_severity_byte_compat
        ] )
    ; ( "round-trip"
      , [ Alcotest.test_case
            "recognised wires round-trip exactly"
            `Quick
            test_round_trip_recognised
        ; Alcotest.test_case
            "parametrised payloads land in Unknown (asymmetric)"
            `Quick
            test_round_trip_lossy_payloads
        ] )
    ; ( "of_termination_code projection"
      , [ Alcotest.test_case
            "every runtime variant projects deterministically"
            `Quick
            test_projection
        ] )
    ; ( "registry failure reason"
      , [ Alcotest.test_case
            "structured runtime no-provider reason is preserved"
            `Quick
            test_registry_failure_reason_preserves_no_provider_runtime_reason
        ; Alcotest.test_case
            "free-form runtime detail stays generic"
            `Quick
            test_registry_failure_reason_does_not_classify_free_form_detail
        ] )
    ; ( "turn finalization"
      , [ Alcotest.test_case
            "missing last_execution returns typed Internal"
            `Quick
            test_missing_last_execution_is_typed_error
        ] )
    ]
;;
