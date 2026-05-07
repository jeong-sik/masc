open Masc_mcp

module KK = Keeper_keepalive
module KTS = Keeper_turn_slot

let with_env name value f =
  let previous = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | Some prior -> Unix.putenv name prior
      | None -> Unix.putenv name "")
    f

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

let test_concurrent_bumps_do_not_lose_updates () =
  let keeper = "parallel-bumps" in
  with_reset keeper (fun () ->
    let workers = 4 in
    let bumps_per_worker = 25 in
    let domains =
      List.init workers (fun _ ->
        Domain.spawn (fun () ->
          for _ = 1 to bumps_per_worker do
            ignore (KK.bump_budget_exhaustion ~keeper_name:keeper : int)
          done))
    in
    List.iter Domain.join domains;
    Alcotest.(check int) "all bumps accounted"
      (workers * bumps_per_worker)
      (KK.peek_budget_exhaustion_for_test ~keeper_name:keeper))

let strike_limit_from_env_for_test () =
  KTS.oas_timeout_budget_strike_limit_int_of_env_default_for_test
    "MASC_KEEPER_OAS_TIMEOUT_BUDGET_STRIKE_LIMIT"
    ~default:3
    ~min_v:1
    ~max_v:100

let test_strike_limit_env_clamps () =
  with_env "MASC_KEEPER_OAS_TIMEOUT_BUDGET_STRIKE_LIMIT" "0" (fun () ->
    Alcotest.(check int) "low clamp" 1
      (strike_limit_from_env_for_test ()));
  with_env "MASC_KEEPER_OAS_TIMEOUT_BUDGET_STRIKE_LIMIT" "250" (fun () ->
    Alcotest.(check int) "high clamp" 100
      (strike_limit_from_env_for_test ()));
  with_env "MASC_KEEPER_OAS_TIMEOUT_BUDGET_STRIKE_LIMIT" "7" (fun () ->
    Alcotest.(check int) "operator value" 7
      (strike_limit_from_env_for_test ()))

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
        Alcotest.test_case "concurrent bumps do not lose updates" `Quick
          test_concurrent_bumps_do_not_lose_updates;
        Alcotest.test_case "strike limit env clamps" `Quick
          test_strike_limit_env_clamps;
      ] );
  ]
