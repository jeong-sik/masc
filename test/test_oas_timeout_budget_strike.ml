open Masc_mcp

module KK = Keeper_keepalive

let with_reset keeper f =
  KK.reset_budget_exhaustion ~keeper_name:keeper;
  Fun.protect
    ~finally:(fun () -> KK.reset_budget_exhaustion ~keeper_name:keeper)
    f

let test_seeded_bump_increments_from_prior () =
  with_reset "seeded" (fun () ->
    let strikes =
      KK.bump_budget_exhaustion_seeded
        ~keeper_name:"seeded"
        ~prior_strikes:2
    in
    Alcotest.(check int) "bump increments from 2 to 3" 3 strikes;
    Alcotest.(check int) "peek sees persisted in-process count" 3
      (KK.peek_budget_exhaustion_for_test ~keeper_name:"seeded"))

let test_in_process_bump_accumulates () =
  with_reset "in-process" (fun () ->
    Alcotest.(check int) "first" 1
      (KK.bump_budget_exhaustion ~keeper_name:"in-process");
    Alcotest.(check int) "second" 2
      (KK.bump_budget_exhaustion ~keeper_name:"in-process"))

let test_seeded_bump_uses_higher_persisted_count () =
  with_reset "seed-max" (fun () ->
    KK.set_budget_exhaustion_for_test ~keeper_name:"seed-max" ~strikes:1;
    let strikes =
      KK.bump_budget_exhaustion_seeded
        ~keeper_name:"seed-max"
        ~prior_strikes:4
    in
    Alcotest.(check int) "seed catches up to persisted count" 5 strikes)

let test_reset_clears () =
  KK.set_budget_exhaustion_for_test ~keeper_name:"reset" ~strikes:2;
  KK.reset_budget_exhaustion ~keeper_name:"reset";
  Alcotest.(check int) "reset clears" 0
    (KK.peek_budget_exhaustion_for_test ~keeper_name:"reset")

let () =
  Alcotest.run "oas_timeout_budget_strike"
  [
    ( "strike ledger",
      [
        Alcotest.test_case "seeded bump increments" `Quick
          test_seeded_bump_increments_from_prior;
        Alcotest.test_case "in-process bump accumulates" `Quick
          test_in_process_bump_accumulates;
        Alcotest.test_case "seeded bump uses higher persisted count" `Quick
          test_seeded_bump_uses_higher_persisted_count;
        Alcotest.test_case "reset clears" `Quick test_reset_clears;
      ] );
  ]
