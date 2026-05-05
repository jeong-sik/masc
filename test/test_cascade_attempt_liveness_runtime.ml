(** Tests for [Cascade_attempt_liveness_runtime] mode-aware decision (RFC-0022 PR-2/4). *)

open Masc_mcp
module L = Cascade_attempt_liveness
module R = Cascade_attempt_liveness_runtime
module Mode = Env_config_keeper.CascadeAttemptLiveness

let pp_failure fmt f =
  Format.pp_print_string fmt (L.failure_kind_label f)

let check_verdict =
  Alcotest.testable
    (fun fmt -> function
      | R.Continue_attempt -> Format.fprintf fmt "Continue_attempt"
      | R.Abort_attempt f ->
          Format.fprintf fmt "Abort_attempt(%a)" pp_failure f)
    ( = )

let check_side_effect =
  Alcotest.testable
    (fun fmt -> function
      | R.Nothing -> Format.fprintf fmt "Nothing"
      | R.Record_kill { kind; mode_label } ->
          Format.fprintf fmt "Record_kill(kind=%a, mode=%s)"
            pp_failure kind mode_label)
    ( = )

(* ──────────────────────── decision-table ──────────────────────── *)

let test_continue_is_inert () =
  let v, fx = R.decide ~mode:Mode.Observe L.Continue in
  Alcotest.check check_verdict "continue" R.Continue_attempt v;
  Alcotest.check check_side_effect "no side effect" R.Nothing fx

let test_completed_is_inert () =
  let v, fx = R.decide ~mode:Mode.Enforce L.Completed in
  Alcotest.check check_verdict "completed" R.Continue_attempt v;
  Alcotest.check check_side_effect "no side effect" R.Nothing fx

let test_outcome_off_no_kill_no_record () =
  let v, fx =
    R.decide ~mode:Mode.Off (L.Outcome L.No_first_token)
  in
  Alcotest.check check_verdict "off swallows the kill" R.Continue_attempt v;
  Alcotest.check check_side_effect "off does not record" R.Nothing fx

let test_outcome_observe_continues_but_records () =
  let v, fx =
    R.decide ~mode:Mode.Observe (L.Outcome L.Inter_chunk_idle)
  in
  Alcotest.check check_verdict "observe never aborts"
    R.Continue_attempt v;
  Alcotest.check check_side_effect "observe records kill"
    (R.Record_kill { kind = L.Inter_chunk_idle; mode_label = "observe" })
    fx

let test_outcome_enforce_aborts_and_records () =
  let v, fx =
    R.decide ~mode:Mode.Enforce (L.Outcome L.Wall_exceeded)
  in
  Alcotest.check check_verdict "enforce aborts"
    (R.Abort_attempt L.Wall_exceeded) v;
  Alcotest.check check_side_effect "enforce records kill"
    (R.Record_kill { kind = L.Wall_exceeded; mode_label = "enforce" })
    fx

let test_provider_error_observe_records_with_kind () =
  let err = L.Provider_error "HTTP 502" in
  let v, fx = R.decide ~mode:Mode.Observe (L.Outcome err) in
  Alcotest.check check_verdict "observe never aborts"
    R.Continue_attempt v;
  Alcotest.check check_side_effect
    "kind is Provider_error preserved on observe"
    (R.Record_kill { kind = err; mode_label = "observe" })
    fx

(* ──────────────────────── mode_label round-trip ──────────────────────── *)

let test_mode_labels_are_lowercase_stable () =
  Alcotest.(check string) "off" "off" (Mode.mode_label Mode.Off);
  Alcotest.(check string) "observe" "observe" (Mode.mode_label Mode.Observe);
  Alcotest.(check string) "enforce" "enforce" (Mode.mode_label Mode.Enforce)

let () =
  let case name f = Alcotest.test_case name `Quick f in
  Alcotest.run "Cascade_attempt_liveness_runtime"
    [
      ( "decide",
        [
          case "Continue → Continue_attempt + Nothing"
            test_continue_is_inert;
          case "Completed → Continue_attempt + Nothing (Enforce)"
            test_completed_is_inert;
          case "Outcome × Off → Continue_attempt + Nothing"
            test_outcome_off_no_kill_no_record;
          case "Outcome × Observe → Continue_attempt + Record_kill"
            test_outcome_observe_continues_but_records;
          case "Outcome × Enforce → Abort_attempt + Record_kill"
            test_outcome_enforce_aborts_and_records;
          case "Provider_error preserved through Record_kill"
            test_provider_error_observe_records_with_kind;
        ] );
      ( "mode_label",
        [
          case "off / observe / enforce stable lowercase"
            test_mode_labels_are_lowercase_stable;
        ] );
    ]
