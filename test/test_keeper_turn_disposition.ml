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
module KTD = Masc.Keeper_turn_driver
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
  ; "post_commit_ambiguous", D.Post_commit_ambiguous
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
  ; ( "agent_error_max_turns_exceeded:turns=10,limit=10"
    , D.Provider_error (Code.Sdk_error "agent_error_max_turns_exceeded:turns=10,limit=10")
    )
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
  ; "Post_commit_ambiguous", D.Post_commit_ambiguous
  ; "Completion_contract_unsatisfied", D.Completion_contract_unsatisfied
  ; "Completion_contract_no_progress", D.Completion_contract_no_progress
  ; ( "Turn_budget_exhausted/Turns/Oas"
    , D.Turn_budget_exhausted
        { detail = Some { dimension = `Turns; source = `Oas_sdk }; used = 10; limit = 10 } )
  ; ( "Turn_budget_exhausted/WallClock/User"
    , D.Turn_budget_exhausted
        { detail = Some { dimension = `Wall_clock_seconds; source = `User_config }
        ; used = 95
        ; limit = 90
        } )
  ; ( "Turn_budget_exhausted/Idle/Keeper"
    , D.Turn_budget_exhausted
        { detail = Some { dimension = `Idle_turns; source = `Keeper_runtime }
        ; used = 3
        ; limit = 2
        } )
  ; (* Detail-less form: the receipt producer
       ([Runtime_agent.TurnBudgetExhausted {turns_used; limit}]) carries no
       dimension/source, so [to_wire] emits "turn_budget_exhausted(<used>/<limit>)"
       and [of_wire] round-trips it to [detail = None]. This is the form whose
       drift (#22618 colon producer vs paren consumer) misreported the dashboard
       budget state. *)
    ( "Turn_budget_exhausted/detail-less"
    , D.Turn_budget_exhausted { detail = None; used = 1070; limit = 1070 } )
  ; "Unknown empty", D.Unknown { raw_error = "" }
  ; "Unknown raw", D.Unknown { raw_error = "fresh_unmapped_label" }
  ; (* Runtime wires that Code.of_wire recognises losslessly (no payload
     or payload-loss is acceptable per RFC-0042 §5.2). *)
    "Provider_error/Heartbeat", D.Provider_error Code.Heartbeat_failures
  ; "Provider_error/Turn_failures", D.Provider_error Code.Turn_failures
  ; "Provider_error/Storm", D.Provider_error Code.Stale_termination_storm
  ; "Provider_error/FleetBatch", D.Provider_error Code.Stale_fleet_batch
  ; "Provider_error/TurnOverflow", D.Provider_error Code.Turn_overflow_pause
  ; "Provider_error/TurnLivelock", D.Provider_error Code.Turn_livelock_pause
  ; "Provider_error/Fiber", D.Provider_error Code.Fiber_unresolved
  ]
;;

(* Documented lossy Turn_budget_exhausted wires — fall back to
   [Unknown { raw_error = original }] per the parser's fail-closed
   contract. The original wire is preserved verbatim for diagnostic
   surfacing so a producer using a stale dimension tag does not silently
   land in a typed bucket. *)
let turn_budget_lossy_wires : (string * string) list =
  [ ( "Turn_budget_exhausted unknown dimension"
    , "turn_budget_exhausted(galactic:oas_sdk:10/10)" )
  ; ( "Turn_budget_exhausted unknown source"
    , "turn_budget_exhausted(turns:galactic:10/10)" )
  ; ( "Turn_budget_exhausted malformed counts"
    , "turn_budget_exhausted(turns:oas_sdk:notanumber/10)" )
  ; ( "Turn_budget_exhausted missing parens"
    , "turn_budget_exhausted turns:oas_sdk:10/10" )
  ; ( "Turn_budget_exhausted missing close paren"
    , "turn_budget_exhausted(turns:oas_sdk:10/10" )
  ; ( "Turn_budget_exhausted extra count segment"
    , "turn_budget_exhausted(turns:oas_sdk:10/10/11)" )
  ; (* Partial tag set (dimension without source) is a mixed form the grammar
       never produces: dimension/source are all-or-nothing. The 2-segment split
       matches neither the full-detail [a;b;c] nor the detail-less [a] arm, so it
       fails closed rather than landing half-tagged. *)
    ( "Turn_budget_exhausted partial tag (dim, no source)"
    , "turn_budget_exhausted(turns:10/10)" )
  ]
;;

let test_turn_budget_lossy_wires_fail_closed () =
  List.iter
    (fun (label, wire) ->
       match D.of_wire wire with
       | D.Unknown { raw_error } ->
         Alcotest.(check string)
           (label ^ " preserves wire verbatim")
           wire
           raw_error
       | other ->
         Alcotest.failf "%s expected Unknown, got %a" label D.pp other)
    turn_budget_lossy_wires
;;

(* Consumer-side grammar pin: the exact wire strings the dashboard /
   runtime-trust snapshot feed into [of_wire]. Asserts the parsed fields
   directly (not just round-trip) so the detail-less producer form and the
   full-detail form both map to the documented typed value. *)
let test_of_wire_parses_both_forms () =
  (match D.of_wire "turn_budget_exhausted(1070/1070)" with
   | D.Turn_budget_exhausted { detail = None; used; limit } ->
     Alcotest.(check int) "detail-less used" 1070 used;
     Alcotest.(check int) "detail-less limit" 1070 limit
   | other ->
     Alcotest.failf "detail-less form: expected None/None fields, got %a" D.pp other);
  match D.of_wire "turn_budget_exhausted(turns:oas_sdk:8/8)" with
  | D.Turn_budget_exhausted
      { detail = Some { dimension = `Turns; source = `Oas_sdk }; used; limit } ->
    Alcotest.(check int) "full-detail used" 8 used;
    Alcotest.(check int) "full-detail limit" 8 limit
  | other ->
    Alcotest.failf "full-detail form: expected Some/Some fields, got %a" D.pp other
;;

(* [is_turn_budget_exhausted_wire] is the predicate the dashboard /
   runtime-trust consumers call. It is strict: only the paren grammar of_wire
   recognises counts as budget-exhausted. The legacy colon form is NOT detected
   (no migration; colon receipts read as not-budget and self-heal next turn).
   This pins the removal of the #22549 colon-tolerant fallback. *)
let test_is_turn_budget_exhausted_wire_strict () =
  Alcotest.(check bool)
    "paren detail-less detected"
    true
    (D.is_turn_budget_exhausted_wire "turn_budget_exhausted(8/8)");
  Alcotest.(check bool)
    "paren full-detail detected"
    true
    (D.is_turn_budget_exhausted_wire "turn_budget_exhausted(turns:oas_sdk:8/8)");
  Alcotest.(check bool)
    "legacy colon NOT detected (strict single grammar)"
    false
    (D.is_turn_budget_exhausted_wire "turn_budget_exhausted:8/8");
  Alcotest.(check bool)
    "non-budget wire not detected"
    false
    (D.is_turn_budget_exhausted_wire "success")
;;

let test_completion_contract_severity_is_bad () =
  Alcotest.(check string)
    "Completion_contract_unsatisfied severity"
    "bad"
    (typed_severity_str (D.severity D.Completion_contract_unsatisfied));
  Alcotest.(check string)
    "Completion_contract_no_progress severity"
    "bad"
    (typed_severity_str (D.severity D.Completion_contract_no_progress))
;;

let test_turn_budget_exhausted_severity_is_bad () =
  Alcotest.(check string)
    "Turn_budget_exhausted severity"
    "bad"
    (typed_severity_str
       (D.severity
          (D.Turn_budget_exhausted
             { detail = Some { dimension = `Turns; source = `Oas_sdk }
             ; used = 10
             ; limit = 10
             })))
;;

let test_completion_contract_next_action () =
  Alcotest.(check (option string))
    "Completion_contract_unsatisfied next_action"
    (Some "inspect_completion_contract")
    (D.next_action D.Completion_contract_unsatisfied);
  Alcotest.(check (option string))
    "Completion_contract_no_progress next_action"
    (Some "resume_or_inspect_completion_contract")
    (D.next_action D.Completion_contract_no_progress)
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
  ; ( "Ambiguous/timeout"
    , Code.Ambiguous_partial_commit_post_commit_timeout
    , D.Post_commit_ambiguous )
  ; ( "Ambiguous/failure"
    , Code.Ambiguous_partial_commit_post_commit_failure
    , D.Post_commit_ambiguous )
  ; "Heartbeat", Code.Heartbeat_failures, D.Provider_error Code.Heartbeat_failures
  ; "Turn_failures", Code.Turn_failures, D.Provider_error Code.Turn_failures
  ; "Storm", Code.Stale_termination_storm, D.Provider_error Code.Stale_termination_storm
  ; "FleetBatch", Code.Stale_fleet_batch, D.Provider_error Code.Stale_fleet_batch
  ; "TurnOverflow", Code.Turn_overflow_pause, D.Provider_error Code.Turn_overflow_pause
  ; "TurnLivelock", Code.Turn_livelock_pause, D.Provider_error Code.Turn_livelock_pause
  ; ( "Provider_runtime"
    , Code.Provider_runtime_error "p"
    , D.Provider_error (Code.Provider_runtime_error "p") )
  ; "Fiber", Code.Fiber_unresolved, D.Provider_error Code.Fiber_unresolved
  ; ( "Exception"
    , Code.Exception_unhandled "x"
    , D.Provider_error (Code.Exception_unhandled "x") )
  ; ( "Sdk"
    , Code.Sdk_error "agent_error_max_turns_exceeded:turns=1,limit=1"
    , D.Provider_error (Code.Sdk_error "agent_error_max_turns_exceeded:turns=1,limit=1") )
  ]
;;

let test_projection () =
  List.iter
    (fun (label, code, expected) ->
       let actual = D.of_termination_code code in
       Alcotest.(check bool) (label ^ " projection") true (D.equal expected actual))
    runtime_codes_to_projection
;;

let test_provider_timeout_terminal_is_provider_error () =
  let err =
    KTD.sdk_error_of_masc_internal_error
      (KTD.Provider_timeout
         { budget_sec = 555.0
         ; keeper_turn_timeout_sec = 600.0
         ; estimated_input_tokens = 4302
         ; source = "first_attempt_adaptive_timeout"
         ; remaining_turn_budget_sec = Some 45.0
         ; min_required_sec = 15.0
         ; phase = "runtime_attempt_watchdog"
         })
  in
  let terminal =
    Legacy.of_failure
      ~raw_error:(Agent_sdk.Error.to_string err)
      err
  in
  Alcotest.(check string)
    "provider timeout terminal code"
    "provider_timeout"
    (Legacy.code terminal);
  Alcotest.(check string)
    "provider timeout disposition"
    "provider_timeout"
    (D.to_wire terminal.disposition)
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

let test_registry_failure_reason_completion_contract_is_typed () =
  let raw_error = "provider returned empty assistant turn" in
  let terminal = Legacy.of_disposition D.Completion_contract_no_progress in
  match Unified_types.registry_failure_reason_of_terminal_reason terminal ~raw_error with
  | Some (Registry.Completion_contract_violation { detail }) ->
    Alcotest.(check string) "typed completion-contract detail" raw_error detail
  | Some other ->
    Alcotest.failf
      "expected Completion_contract_violation, got %s"
      (Registry.failure_reason_to_string other)
  | None -> Alcotest.fail "expected typed completion-contract failure reason"
;;

let empty_turn_state : Unified_types.turn_state =
  { cycle_completed = false
  ; manifest_seq = 0
  ; post_commit_failure_reason = None
  ; paused_meta_override = None
  ; current_turn_blocker_info = None
  ; last_execution = None
  ; last_provider_timeout_budget = None
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
        ; Alcotest.test_case
            "Turn_budget_exhausted malformed wires fail closed"
            `Quick
            test_turn_budget_lossy_wires_fail_closed
        ; Alcotest.test_case
            "of_wire parses both detail-less and full-detail forms"
            `Quick
            test_of_wire_parses_both_forms
        ; Alcotest.test_case
            "is_turn_budget_exhausted_wire is strict paren-only"
            `Quick
            test_is_turn_budget_exhausted_wire_strict
        ] )
    ; ( "completion-contract typed accessors (RFC-0047 PR-2)"
      , [ Alcotest.test_case
            "severity is bad"
            `Quick
            test_completion_contract_severity_is_bad
        ; Alcotest.test_case
            "next_action dispatches to resume/inspect"
            `Quick
            test_completion_contract_next_action
        ] )
    ; ( "Turn_budget_exhausted typed accessors"
      , [ Alcotest.test_case
            "severity is bad"
            `Quick
            test_turn_budget_exhausted_severity_is_bad
        ] )
    ; ( "of_termination_code projection"
      , [ Alcotest.test_case
            "every runtime variant projects deterministically"
            `Quick
            test_projection
        ; Alcotest.test_case
            "provider timeout is provider error, not turn wall-clock"
            `Quick
            test_provider_timeout_terminal_is_provider_error
        ] )
    ; ( "registry failure reason"
      , [ Alcotest.test_case
            "structured runtime no-provider reason is preserved"
            `Quick
            test_registry_failure_reason_preserves_no_provider_runtime_reason
        ; Alcotest.test_case
            "completion contract disposition creates typed failure reason"
            `Quick
            test_registry_failure_reason_completion_contract_is_typed
        ] )
    ; ( "turn finalization"
      , [ Alcotest.test_case
            "missing last_execution returns typed Internal"
            `Quick
            test_missing_last_execution_is_typed_error
        ] )
    ]
;;
