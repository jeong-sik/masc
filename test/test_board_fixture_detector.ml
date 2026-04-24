(* test/test_board_fixture_detector.ml

   #9921: detector for test-fixture contamination in persisted
   vote ledger. The test-side regression vector (pre-2026-04-18
   dune env-vars block) is closed, but the historical pollution
   remains in live prod data. This detector surfaces it at load
   time instead of letting the ledger silently reinforce it.

   Invariants under test:
   1. [is_fixture_voter_target] flags [hot-voter-*],
      [synthetic-voter-*], [:test-voter-*] patterns.
   2. Real keeper names (keeper-*, agent-*, anyang-keepers) are
      NOT flagged — zero false positives on known production
      voter shapes.
   3. [quarantine_enabled] reads MASC_BOARD_VOTE_QUARANTINE:
      "1" / "true" (case-insensitive) → true, anything else →
      false. Empty / unset → false (warn-only default). *)

module BV = Masc_mcp.Board_votes

let test_hot_voter_flagged () =
  Alcotest.(check bool) "hot-voter-067 flagged" true
    (BV.is_fixture_voter_target "post:p-abc:hot-voter-067");
  Alcotest.(check bool) "hot-voter-001 flagged" true
    (BV.is_fixture_voter_target "post:xyz:hot-voter-001")

let test_synthetic_voter_flagged () =
  Alcotest.(check bool) "synthetic-voter- flagged" true
    (BV.is_fixture_voter_target "post:p-xyz:synthetic-voter-12")

let test_test_voter_flagged () =
  Alcotest.(check bool) ":test-voter- flagged" true
    (BV.is_fixture_voter_target "post:p-xyz:test-voter-01")

let test_real_keeper_names_not_flagged () =
  let cases = [
    "post:hot-voter-topic:keeper-taskmaster-agent";
    "post:p-abc:keeper-taskmaster-agent";
    "post:p-abc:sangsu";
    "post:p-abc:anyang-keepers";
    "post:p-abc:codex-mcp-client";
    "post:p-abc:keeper-alert-bot";
    "post:p-abc:keeper-ramarama-agent";
    "post:p-abc:nick0cave";
    (* Names containing 'voter' but NOT the fixture shapes *)
    "post:p-abc:promoter";
    "post:p-abc:devoter-bot";
  ] in
  List.iter (fun s ->
    Alcotest.(check (pair string bool)) s (s, false)
      (s, BV.is_fixture_voter_target s))
    cases

let test_quarantine_default_off () =
  Unix.putenv "MASC_BOARD_VOTE_QUARANTINE" "";
  Alcotest.(check bool) "empty → off" false (BV.quarantine_enabled ());
  Unix.putenv "MASC_BOARD_VOTE_QUARANTINE" "0";
  Alcotest.(check bool) "0 → off" false (BV.quarantine_enabled ())

let test_quarantine_on_values () =
  Unix.putenv "MASC_BOARD_VOTE_QUARANTINE" "1";
  Alcotest.(check bool) "1 → on" true (BV.quarantine_enabled ());
  Unix.putenv "MASC_BOARD_VOTE_QUARANTINE" "true";
  Alcotest.(check bool) "true → on" true (BV.quarantine_enabled ());
  Unix.putenv "MASC_BOARD_VOTE_QUARANTINE" "TRUE";
  Alcotest.(check bool) "TRUE → on" true (BV.quarantine_enabled ());
  Unix.putenv "MASC_BOARD_VOTE_QUARANTINE" ""

let test_empty_target_not_flagged () =
  Alcotest.(check bool) "empty string safe" false
    (BV.is_fixture_voter_target "");
  Alcotest.(check bool) "partial keyword safe" false
    (BV.is_fixture_voter_target "hot")

let () =
  Alcotest.run "board_fixture_detector"
    [
      ( "fixture patterns",
        [
          Alcotest.test_case "hot-voter-*" `Quick test_hot_voter_flagged;
          Alcotest.test_case "synthetic-voter-*" `Quick
            test_synthetic_voter_flagged;
          Alcotest.test_case ":test-voter-*" `Quick test_test_voter_flagged;
          Alcotest.test_case "empty / partial safe" `Quick
            test_empty_target_not_flagged;
        ] );
      ( "false positives",
        [
          Alcotest.test_case "real keeper names NOT flagged" `Quick
            test_real_keeper_names_not_flagged;
        ] );
      ( "quarantine env gate",
        [
          Alcotest.test_case "default off" `Quick test_quarantine_default_off;
          Alcotest.test_case "truthy values → on" `Quick
            test_quarantine_on_values;
        ] );
    ]
