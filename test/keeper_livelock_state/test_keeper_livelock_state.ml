(* Standalone Alcotest unit tests for [Keeper_livelock_state]. *)

open Keeper_livelock_state

let reset () = reset_for_test ()

let test_gate_kind_roundtrip () =
  List.iter
    (fun gk ->
      let s = gate_kind_to_string gk in
      match gate_kind_of_string s with
      | Some gk' ->
        Alcotest.(check string)
          (Printf.sprintf "roundtrip %s" s)
          (gate_kind_to_string gk)
          (gate_kind_to_string gk')
      | None ->
        Alcotest.failf "gate_kind_of_string returned None for %s" s)
    all_gate_kinds
;;

let test_gate_kind_unknown_label () =
  match gate_kind_of_string "not_a_real_kind" with
  | None -> ()
  | Some _ ->
    Alcotest.fail "expected None for unknown label, got Some _"
;;

let test_first_block_returns_first () =
  reset ();
  let out =
    record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted ()
  in
  match out with
  | `First -> ()
  | `Repeated _ -> Alcotest.fail "expected `First, got `Repeated"
  | `Threshold_park _ ->
    Alcotest.fail "expected `First, got `Threshold_park"
;;

let test_second_block_returns_repeated_with_count_2 () =
  reset ();
  let _ : record_outcome =
    record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted ()
  in
  let out =
    record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted ()
  in
  match out with
  | `Repeated n ->
    Alcotest.(check int) "count should be 2" 2 n
  | `First -> Alcotest.fail "expected `Repeated, got `First"
  | `Threshold_park _ ->
    Alcotest.fail "expected `Repeated, got `Threshold_park"
;;

let test_threshold_park_fires_at_threshold () =
  reset ();
  let threshold = 5 in
  (* First four blocks: `First then 3× `Repeated. *)
  for _ = 1 to threshold - 1 do
    let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
    ()
  done;
  let out =
    record_block
      ~park_threshold:threshold
      ~keeper:"alpha"
      ~gate_kind:Attempts_exhausted
      ()
  in
  match out with
  | `Threshold_park { count; park_threshold } ->
    Alcotest.(check int) "count at threshold" threshold count;
    Alcotest.(check int) "park_threshold echoes input" threshold park_threshold
  | `First -> Alcotest.fail "expected `Threshold_park, got `First"
  | `Repeated _ ->
    Alcotest.fail "expected `Threshold_park, got `Repeated"
;;

let test_threshold_park_fires_only_once () =
  reset ();
  let threshold = 3 in
  for _ = 1 to threshold do
    let _ =
      record_block
        ~park_threshold:threshold
        ~keeper:"alpha"
        ~gate_kind:Attempts_exhausted
        ()
    in
    ()
  done;
  let out =
    record_block
      ~park_threshold:threshold
      ~keeper:"alpha"
      ~gate_kind:Attempts_exhausted
      ()
  in
  match out with
  | `Repeated n ->
    Alcotest.(check int)
      "post-park blocks return Repeated with running count"
      (threshold + 1)
      n
  | `First ->
    Alcotest.fail "expected `Repeated after park, got `First"
  | `Threshold_park _ ->
    Alcotest.fail "expected `Repeated after park, got second `Threshold_park"
;;

let test_distinct_keepers_independent () =
  reset ();
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  let out =
    record_block ~keeper:"beta" ~gate_kind:Attempts_exhausted ()
  in
  match out with
  | `First -> ()
  | _ ->
    Alcotest.fail "expected `First for fresh keeper beta"
;;

let test_distinct_gate_kinds_independent () =
  reset ();
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  let out =
    record_block ~keeper:"alpha" ~gate_kind:Stuck_age_exceeded ()
  in
  match out with
  | `First -> ()
  | _ ->
    Alcotest.fail "expected `First for fresh gate_kind"
;;

let test_reset_for_keeper_clears_only_that_keeper () =
  reset ();
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  let _ = record_block ~keeper:"beta" ~gate_kind:Attempts_exhausted () in
  reset_for_keeper ~keeper:"alpha";
  Alcotest.(check int)
    "alpha block_count after reset_for_keeper"
    0
    (block_count ~keeper:"alpha" ~gate_kind:Attempts_exhausted);
  Alcotest.(check int)
    "beta block_count untouched"
    1
    (block_count ~keeper:"beta" ~gate_kind:Attempts_exhausted)
;;

let test_reset_for_keeper_clears_all_gate_kinds () =
  reset ();
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  let _ = record_block ~keeper:"alpha" ~gate_kind:Stuck_age_exceeded () in
  reset_for_keeper ~keeper:"alpha";
  Alcotest.(check int)
    "Attempts_exhausted cleared"
    0
    (block_count ~keeper:"alpha" ~gate_kind:Attempts_exhausted);
  Alcotest.(check int)
    "Stuck_age_exceeded cleared"
    0
    (block_count ~keeper:"alpha" ~gate_kind:Stuck_age_exceeded)
;;

let test_cardinality_tracks_distinct_pairs () =
  reset ();
  Alcotest.(check int) "empty" 0 (cardinality ());
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  Alcotest.(check int) "one pair" 1 (cardinality ());
  let _ = record_block ~keeper:"alpha" ~gate_kind:Attempts_exhausted () in
  Alcotest.(check int) "same pair, still 1" 1 (cardinality ());
  let _ = record_block ~keeper:"alpha" ~gate_kind:Stuck_age_exceeded () in
  Alcotest.(check int) "second kind" 2 (cardinality ());
  let _ = record_block ~keeper:"beta" ~gate_kind:Attempts_exhausted () in
  Alcotest.(check int) "second keeper" 3 (cardinality ())
;;

let test_block_count_zero_for_missing () =
  reset ();
  Alcotest.(check int)
    "missing pair returns 0"
    0
    (block_count ~keeper:"never_seen" ~gate_kind:Attempts_exhausted)
;;

(* Regression-style scenario: replay the production fingerprint of
   2026-05-19 — 4 keepers, each blocked many times on
   Attempts_exhausted. The first block of each keeper should be
   [`First] (operator-visible ERROR), the next [park_threshold-1]
   blocks should be [`Repeated], the [park_threshold]th block should
   be [`Threshold_park] (durable ERROR), and any further blocks
   should fold into [`Repeated]. *)
let test_production_scenario_4_keepers () =
  reset ();
  let threshold = 5 in
  let keepers = [ "sangsu"; "nick0cave"; "echo"; "analyst" ] in
  List.iter
    (fun k ->
      let first_outcome =
        record_block
          ~park_threshold:threshold
          ~keeper:k
          ~gate_kind:Attempts_exhausted
          ()
      in
      (match first_outcome with
       | `First -> ()
       | _ -> Alcotest.failf "%s: first block was not `First" k);
      for _ = 2 to threshold - 1 do
        let out =
          record_block
            ~park_threshold:threshold
            ~keeper:k
            ~gate_kind:Attempts_exhausted
            ()
        in
        match out with
        | `Repeated _ -> ()
        | _ ->
          Alcotest.failf
            "%s: pre-threshold block did not classify as `Repeated"
            k
      done;
      let park_outcome =
        record_block
          ~park_threshold:threshold
          ~keeper:k
          ~gate_kind:Attempts_exhausted
          ()
      in
      (match park_outcome with
       | `Threshold_park { count; park_threshold = pt } ->
         Alcotest.(check int)
           (Printf.sprintf "%s: park count" k)
           threshold
           count;
         Alcotest.(check int)
           (Printf.sprintf "%s: park_threshold echoed" k)
           threshold
           pt
       | _ ->
         Alcotest.failf "%s: did not Threshold_park at #%d" k threshold);
      (* Simulate the 25–29 follow-up blocks observed in 10 min
         system_log slice. None should produce a second
         Threshold_park. *)
      for _ = threshold + 1 to threshold + 25 do
        let out =
          record_block
            ~park_threshold:threshold
            ~keeper:k
            ~gate_kind:Attempts_exhausted
            ()
        in
        match out with
        | `Repeated _ -> ()
        | _ ->
          Alcotest.failf
            "%s: post-park block did not classify as `Repeated"
            k
      done)
    keepers;
  Alcotest.(check int)
    "4 distinct (keeper, gate_kind) pairs registered"
    4
    (cardinality ())
;;

let () =
  Alcotest.run
    "keeper_livelock_state"
    [ ( "gate_kind"
      , [ Alcotest.test_case "roundtrip" `Quick test_gate_kind_roundtrip
        ; Alcotest.test_case
            "unknown_label_returns_None"
            `Quick
            test_gate_kind_unknown_label
        ] )
    ; ( "record_block"
      , [ Alcotest.test_case "first" `Quick test_first_block_returns_first
        ; Alcotest.test_case
            "second_returns_repeated_2"
            `Quick
            test_second_block_returns_repeated_with_count_2
        ; Alcotest.test_case
            "threshold_park"
            `Quick
            test_threshold_park_fires_at_threshold
        ; Alcotest.test_case
            "threshold_park_only_once"
            `Quick
            test_threshold_park_fires_only_once
        ; Alcotest.test_case
            "distinct_keepers_independent"
            `Quick
            test_distinct_keepers_independent
        ; Alcotest.test_case
            "distinct_gate_kinds_independent"
            `Quick
            test_distinct_gate_kinds_independent
        ] )
    ; ( "reset"
      , [ Alcotest.test_case
            "reset_for_keeper_targeted"
            `Quick
            test_reset_for_keeper_clears_only_that_keeper
        ; Alcotest.test_case
            "reset_for_keeper_all_kinds"
            `Quick
            test_reset_for_keeper_clears_all_gate_kinds
        ] )
    ; ( "introspection"
      , [ Alcotest.test_case
            "cardinality"
            `Quick
            test_cardinality_tracks_distinct_pairs
        ; Alcotest.test_case
            "block_count_zero_for_missing"
            `Quick
            test_block_count_zero_for_missing
        ] )
    ; ( "production_scenario"
      , [ Alcotest.test_case
            "4_keepers_2026_05_19"
            `Quick
            test_production_scenario_4_keepers
        ] )
    ]
;;
