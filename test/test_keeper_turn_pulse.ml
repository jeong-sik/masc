module Pulse = Masc.Keeper_turn_pulse

let test_empty_pulse_returns_none () =
  Pulse.reset_for_tests ();
  Alcotest.(check bool)
    "unknown keeper has no pulse"
    true
    (Pulse.get ~base_path:"/tmp/p1" ~keeper_name:"k1" = None)
;;

let test_record_and_ordering () =
  Pulse.reset_for_tests ();
  let base_path = "/tmp/p1" in
  let keeper = "alpha" in
  Pulse.record ~base_path ~keeper_name:keeper ~at:100.0 Pulse.Turn_ok;
  Pulse.record ~base_path ~keeper_name:keeper ~at:105.0 Pulse.Turn_rested;
  Pulse.record ~base_path ~keeper_name:keeper ~at:110.0 Pulse.Turn_failed;
  match Pulse.get ~base_path ~keeper_name:keeper with
  | None -> Alcotest.fail "expected pulse entry"
  | Some pulse ->
    Alcotest.(check bool) "not truncated within capacity" false pulse.truncated;
    Alcotest.(check int) "3 samples" 3 (List.length pulse.samples);
    let newest = List.hd pulse.samples in
    Alcotest.(check (float 0.001)) "newest at" 110.0 newest.at;
    Alcotest.(check string) "newest outcome" "failed" (Pulse.outcome_to_string newest.outcome);
    let outcomes = List.map (fun (s : Pulse.sample) -> Pulse.outcome_to_string s.outcome) pulse.samples in
    Alcotest.(check (list string)) "outcomes newest first" [ "failed"; "rested"; "ok" ] outcomes
;;

let test_capacity_truncation () =
  Pulse.reset_for_tests ();
  let base_path = "/tmp/p1" in
  let keeper = "beta" in
  for i = 1 to 30 do
    Pulse.record
      ~base_path
      ~keeper_name:keeper
      ~at:(float_of_int (1000 + i))
      (if i mod 2 = 0 then Pulse.Turn_ok else Pulse.Turn_failed)
  done;
  match Pulse.get ~base_path ~keeper_name:keeper with
  | None -> Alcotest.fail "expected pulse entry"
  | Some pulse ->
    Alcotest.(check bool) "truncated becomes true when exceeding capacity" true pulse.truncated;
    Alcotest.(check int)
      "capped at max_samples_per_keeper"
      Pulse.max_samples_per_keeper
      (List.length pulse.samples);
    let newest = List.hd pulse.samples in
    Alcotest.(check (float 0.001)) "newest sample is 1030" 1030.0 newest.at;
    let oldest = List.nth pulse.samples (Pulse.max_samples_per_keeper - 1) in
    Alcotest.(check (float 0.001)) "oldest preserved is 1007" 1007.0 oldest.at
;;

let test_isolation () =
  Pulse.reset_for_tests ();
  Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"k1" ~at:10.0 Pulse.Turn_ok;
  Pulse.record ~base_path:"/tmp/p2" ~keeper_name:"k1" ~at:20.0 Pulse.Turn_failed;
  Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"k2" ~at:30.0 Pulse.Turn_rested;
  let p1_k1 = Option.get (Pulse.get ~base_path:"/tmp/p1" ~keeper_name:"k1") in
  let p2_k1 = Option.get (Pulse.get ~base_path:"/tmp/p2" ~keeper_name:"k1") in
  let p1_k2 = Option.get (Pulse.get ~base_path:"/tmp/p1" ~keeper_name:"k2") in
  Alcotest.(check (float 0.001)) "p1 k1 at" 10.0 (List.hd p1_k1.samples).at;
  Alcotest.(check (float 0.001)) "p2 k1 at" 20.0 (List.hd p2_k1.samples).at;
  Alcotest.(check (float 0.001)) "p1 k2 at" 30.0 (List.hd p1_k2.samples).at
;;

let test_seed () =
  Pulse.reset_for_tests ();
  let base_path = "/tmp/p1" in
  let keeper = "gamma" in
  let initial_samples : Pulse.sample list =
    [ { at = 50.0; outcome = Pulse.Turn_ok }
    ; { at = 40.0; outcome = Pulse.Turn_failed }
    ]
  in
  Pulse.seed ~base_path ~keeper_name:keeper ~samples:initial_samples ~truncated:false ();
  (match Pulse.get ~base_path ~keeper_name:keeper with
   | None -> Alcotest.fail "expected seeded pulse"
   | Some pulse ->
     Alcotest.(check bool) "not truncated" false pulse.truncated;
     Alcotest.(check int) "2 seeded samples" 2 (List.length pulse.samples));
  (* Seed again without override should be ignored *)
  Pulse.seed
    ~base_path
    ~keeper_name:keeper
    ~samples:[ { at = 999.0; outcome = Pulse.Turn_rested } ]
    ~truncated:true
    ();
  (match Pulse.get ~base_path ~keeper_name:keeper with
   | None -> Alcotest.fail "expected seeded pulse"
   | Some pulse ->
     Alcotest.(check (float 0.001)) "still original 50.0" 50.0 (List.hd pulse.samples).at);
  (* Recording live turn prepends to seeded history *)
  Pulse.record ~base_path ~keeper_name:keeper ~at:60.0 Pulse.Turn_rested;
  (match Pulse.get ~base_path ~keeper_name:keeper with
   | None -> Alcotest.fail "expected pulse"
   | Some pulse ->
     Alcotest.(check int) "3 samples now" 3 (List.length pulse.samples);
     Alcotest.(check (float 0.001)) "newest is 60.0" 60.0 (List.hd pulse.samples).at)
;;

let test_outcome_string_roundtrip () =
  Alcotest.(check string) "ok" "ok" (Pulse.outcome_to_string Pulse.Turn_ok);
  Alcotest.(check string) "rested" "rested" (Pulse.outcome_to_string Pulse.Turn_rested);
  Alcotest.(check string) "failed" "failed" (Pulse.outcome_to_string Pulse.Turn_failed);
  Alcotest.(check bool) "of ok" true (Pulse.outcome_of_string "ok" = Some Pulse.Turn_ok);
  Alcotest.(check bool)
    "of rested"
    true
    (Pulse.outcome_of_string "rested" = Some Pulse.Turn_rested);
  Alcotest.(check bool)
    "of failed"
    true
    (Pulse.outcome_of_string "failed" = Some Pulse.Turn_failed);
  Alcotest.(check bool) "of unknown" true (Pulse.outcome_of_string "cancelled" = None)
;;

let test_sample_of_decision_line () =
  let valid_turn = {|{"event":"turn","ts_unix":1794037335.0,"outcome":"success"}|} in
  (match Pulse.sample_of_decision_line valid_turn with
   | None -> Alcotest.fail "expected sample"
   | Some s ->
     Alcotest.(check (float 0.001)) "ts" 1794037335.0 s.at;
     Alcotest.(check bool) "outcome ok" true (s.outcome = Pulse.Turn_ok));
  let failed_turn = {|{"event":"turn","ts_unix":1794036000.0,"outcome":"error"}|} in
  (match Pulse.sample_of_decision_line failed_turn with
   | None -> Alcotest.fail "expected sample"
   | Some s ->
     Alcotest.(check (float 0.001)) "ts" 1794036000.0 s.at;
     Alcotest.(check bool) "outcome failed" true (s.outcome = Pulse.Turn_failed));
  let non_turn = {|{"event":"heartbeat","ts_unix":1794035000.0,"outcome":"success"}|} in
  Alcotest.(check bool) "ignore non-turn" true (Pulse.sample_of_decision_line non_turn = None);
  let bad_json = "not json" in
  Alcotest.(check bool) "ignore bad json" true (Pulse.sample_of_decision_line bad_json = None)
;;

let () =
  Alcotest.run
    "keeper_turn_pulse"
    [ ( "pulse"
      , [ Alcotest.test_case "empty returns none" `Quick test_empty_pulse_returns_none
        ; Alcotest.test_case "record and ordering" `Quick test_record_and_ordering
        ; Alcotest.test_case "capacity truncation" `Quick test_capacity_truncation
        ; Alcotest.test_case "isolation" `Quick test_isolation
        ; Alcotest.test_case "seed" `Quick test_seed
        ; Alcotest.test_case "sample of decision line" `Quick test_sample_of_decision_line
        ; Alcotest.test_case "outcome string roundtrip" `Quick test_outcome_string_roundtrip
        ] )
    ]
;;
