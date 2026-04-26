(** Tests for Keeper_behavioral_regime — 7th FSM axis MVP deriver.

    The deriver is a pure function over a small input record so each
    boundary case can be tested in isolation, without constructing a
    full [Keeper_registry.registry_entry]. *)

open Alcotest
module R = Masc_mcp.Keeper_behavioral_regime

let now = 1_000_000.0

let healthy_input : R.input =
  { turn_consecutive_failures = 0
  ; restart_count = 0
  ; last_restart_ts = 0.0
  ; tool_aggregates = []
  }
;;

let regime_testable =
  testable
    (fun fmt r -> Format.pp_print_string fmt (R.string_of_regime r))
    (fun a b -> R.string_of_regime a = R.string_of_regime b)
;;

(* ── Healthy: baseline ──────────────────────────────────── *)

let test_healthy_default () =
  let s = R.derive ~now healthy_input in
  check regime_testable "default is Healthy" R.Healthy s.regime;
  check string "default rule_id" "default_healthy" s.reason.rule_id;
  check (list string) "no evidence" [] s.reason.evidence
;;

(* ── Thrashing: turn failure streak ─────────────────────── *)

let test_turn_streak_below_threshold_is_healthy () =
  let input =
    { healthy_input with turn_consecutive_failures = R.turn_fail_streak_threshold - 1 }
  in
  let s = R.derive ~now input in
  check regime_testable "N-1 failures stays Healthy" R.Healthy s.regime
;;

let test_turn_streak_at_threshold_is_thrashing () =
  let input =
    { healthy_input with turn_consecutive_failures = R.turn_fail_streak_threshold }
  in
  let s = R.derive ~now input in
  check regime_testable "N failures flips to Thrashing" R.Thrashing s.regime;
  check string "turn_fail_streak rule fired" "turn_fail_streak" s.reason.rule_id
;;

(* ── Thrashing: tool failure saturation ─────────────────── *)

let test_tool_saturated_is_thrashing () =
  let input =
    { healthy_input with
      tool_aggregates =
        [ "read_file", { R.count = 10; failures = 8 } (* 0.8 ratio, 8 fails *) ]
    }
  in
  let s = R.derive ~now input in
  check regime_testable "saturated tool → Thrashing" R.Thrashing s.regime;
  check
    string
    "tool_failure_saturation rule fired"
    "tool_failure_saturation"
    s.reason.rule_id
;;

let test_tool_below_count_threshold_is_healthy () =
  let input =
    { healthy_input with
      (* failures below count threshold even though ratio is 1.0 *)
      tool_aggregates = [ "x", { R.count = 2; failures = 2 } ]
    }
  in
  let s = R.derive ~now input in
  check regime_testable "2 failures stays Healthy" R.Healthy s.regime
;;

let test_tool_below_ratio_threshold_is_healthy () =
  let input =
    { healthy_input with
      (* 5 failures but ratio 0.5 < 0.7 threshold *)
      tool_aggregates = [ "x", { R.count = 10; failures = 5 } ]
    }
  in
  let s = R.derive ~now input in
  check regime_testable "low-ratio tool stays Healthy" R.Healthy s.regime
;;

(* ── Crashing: recent restart streak ────────────────────── *)

let test_restart_within_window_is_crashing () =
  let input =
    { healthy_input with
      restart_count = R.recent_restart_count_threshold
    ; last_restart_ts = now -. 60.0 (* within 5 min window *)
    }
  in
  let s = R.derive ~now input in
  check regime_testable "recent restart → Crashing" R.Crashing s.regime;
  check string "recent_restart_streak rule fired" "recent_restart_streak" s.reason.rule_id
;;

let test_restart_outside_window_is_healthy () =
  let input =
    { healthy_input with
      restart_count = 5
    ; last_restart_ts = now -. (R.recent_restart_window_sec +. 10.0)
    }
  in
  let s = R.derive ~now input in
  check regime_testable "old restart does not linger" R.Healthy s.regime
;;

let test_single_restart_is_healthy () =
  let input = { healthy_input with restart_count = 1; last_restart_ts = now -. 1.0 } in
  let s = R.derive ~now input in
  check regime_testable "one restart below threshold" R.Healthy s.regime
;;

(* ── Precedence: Crashing beats Thrashing ───────────────── *)

let test_crashing_takes_precedence_over_thrashing () =
  let input : R.input =
    { (* both restart streak AND turn fail streak firing *)
      turn_consecutive_failures = R.turn_fail_streak_threshold + 5
    ; restart_count = R.recent_restart_count_threshold + 1
    ; last_restart_ts = now -. 10.0
    ; tool_aggregates = []
    }
  in
  let s = R.derive ~now input in
  check regime_testable "Crashing wins" R.Crashing s.regime;
  check
    string
    "Crashing rule reported, not Thrashing"
    "recent_restart_streak"
    s.reason.rule_id
;;

(* ── Evidence includes concrete values ──────────────────── *)

let test_turn_streak_evidence_includes_value () =
  let input = { healthy_input with turn_consecutive_failures = 7 } in
  let s = R.derive ~now input in
  check
    (list string)
    "evidence carries the exact count"
    [ "turn_consecutive_failures=7" ]
    s.reason.evidence
;;

(* ── Enum round-trip ────────────────────────────────────── *)

let test_regime_string_roundtrip () =
  List.iter
    (fun r ->
       let s = R.string_of_regime r in
       match R.regime_of_string s with
       | Some r' -> check regime_testable (Printf.sprintf "roundtrip %s" s) r r'
       | None -> failf "regime_of_string did not parse %S" s)
    R.all_regimes
;;

(* ── JSON shape is stable ───────────────────────────────── *)

let test_snapshot_json_shape () =
  let s : R.snapshot =
    { regime = R.Thrashing
    ; reason =
        { rule_id = "turn_fail_streak"; evidence = [ "turn_consecutive_failures=5" ] }
    ; updated_at = 1234567890.0
    }
  in
  let json = R.snapshot_to_json s in
  let expected =
    `Assoc
      [ "regime", `String "thrashing"
      ; "rule_id", `String "turn_fail_streak"
      ; "evidence", `List [ `String "turn_consecutive_failures=5" ]
      ; "updated_at", `Float 1234567890.0
      ]
  in
  check
    string
    "JSON matches stable shape"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)
;;

let () =
  run
    "keeper_behavioral_regime"
    [ "default", [ test_case "healthy is default" `Quick test_healthy_default ]
    ; ( "thrashing_turn_streak"
      , [ test_case
            "below threshold is healthy"
            `Quick
            test_turn_streak_below_threshold_is_healthy
        ; test_case
            "at threshold flips to thrashing"
            `Quick
            test_turn_streak_at_threshold_is_thrashing
        ; test_case
            "evidence includes value"
            `Quick
            test_turn_streak_evidence_includes_value
        ] )
    ; ( "thrashing_tool_saturation"
      , [ test_case "saturated tool is thrashing" `Quick test_tool_saturated_is_thrashing
        ; test_case
            "low count stays healthy"
            `Quick
            test_tool_below_count_threshold_is_healthy
        ; test_case
            "low ratio stays healthy"
            `Quick
            test_tool_below_ratio_threshold_is_healthy
        ] )
    ; ( "crashing"
      , [ test_case "recent restart streak" `Quick test_restart_within_window_is_crashing
        ; test_case "old restart expires" `Quick test_restart_outside_window_is_healthy
        ; test_case "single restart stays healthy" `Quick test_single_restart_is_healthy
        ] )
    ; ( "precedence"
      , [ test_case
            "crashing beats thrashing"
            `Quick
            test_crashing_takes_precedence_over_thrashing
        ] )
    ; ( "serialisation"
      , [ test_case "regime string roundtrip" `Quick test_regime_string_roundtrip
        ; test_case "snapshot json shape" `Quick test_snapshot_json_shape
        ] )
    ]
;;
