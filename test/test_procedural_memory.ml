(** Regression tests for procedural-memory crystallization thresholds. *)

open Alcotest
module P = Masc_mcp.Procedural_memory

let procedure ?(evidence = []) ?(success_count = 0) ?(failure_count = 0)
    ?(confidence = 0.0) () : P.procedure =
  {
    id = "proc-test";
    agent_name = "keeper";
    pattern = "When a pattern appears, reuse the learned action";
    evidence;
    success_count;
    failure_count;
    confidence;
    created_at = 0.0;
    last_applied = 0.0;
  }
;;

let test_standard_threshold_crystallizes () =
  let p =
    procedure ~evidence:[ "a"; "b"; "c" ] ~success_count:7 ~failure_count:3
      ~confidence:0.7 ()
  in
  check bool "3 evidence at 70 percent crystallizes" true (P.is_crystallized p)
;;

let test_standard_threshold_rejects_low_confidence () =
  let p =
    procedure ~evidence:[ "a"; "b"; "c" ] ~success_count:2 ~failure_count:1
      ~confidence:0.69 ()
  in
  check bool "3 evidence below confidence threshold is not crystallized" false
    (P.is_crystallized p)
;;

let test_rare_perfect_crystallizes () =
  let p =
    procedure ~evidence:[ "a"; "b" ] ~success_count:2 ~failure_count:0
      ~confidence:1.0 ()
  in
  check bool "2 perfect outcomes crystallize" true (P.is_crystallized p)
;;

let test_rare_near_perfect_does_not_crystallize () =
  let p =
    procedure ~evidence:[ "a"; "b" ] ~success_count:99 ~failure_count:1
      ~confidence:0.99 ()
  in
  check bool "2 near-perfect outcomes do not bypass standard threshold" false
    (P.is_crystallized p)
;;

let test_single_perfect_does_not_crystallize () =
  let p =
    procedure ~evidence:[ "a" ] ~success_count:1 ~failure_count:0
      ~confidence:1.0 ()
  in
  check bool "single perfect outcome is not enough evidence" false
    (P.is_crystallized p)
;;

let () =
  run "procedural_memory"
    [
      ( "crystallization",
        [
          test_case "standard threshold crystallizes" `Quick
            test_standard_threshold_crystallizes;
          test_case "standard threshold rejects low confidence" `Quick
            test_standard_threshold_rejects_low_confidence;
          test_case "rare perfect crystallizes" `Quick test_rare_perfect_crystallizes;
          test_case "rare near-perfect does not crystallize" `Quick
            test_rare_near_perfect_does_not_crystallize;
          test_case "single perfect does not crystallize" `Quick
            test_single_perfect_does_not_crystallize;
        ] );
    ]
;;
