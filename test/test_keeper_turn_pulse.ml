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

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path
;;

(* A directory in place of a decision log exists, so the file-exists check
   passes, and every read of it fails. That is a log the pulse cannot read, as
   opposed to a log that is missing or holds no turns. *)
let test_seed_from_decision_log_read_error () =
  Pulse.reset_for_tests ();
  let base_dir = Filename.temp_dir "keeper-turn-pulse-seed" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       let log_path keeper_name =
         Masc.Keeper_types_support.keeper_decision_log_path config keeper_name
       in
       let seeded keeper_name =
         Pulse.seed_from_decision_log ~now:1794037335.0 ~config ~keeper_name ();
         Pulse.get ~base_path:config.Masc.Workspace.base_path ~keeper_name
       in
       let turn_line = {|{"event":"turn","ts_unix":1794037000.0,"outcome":"success"}|} in
       let write_log path =
         Out_channel.with_open_text path (fun oc -> output_string oc (turn_line ^ "\n"))
       in
       (match seeded "no-log" with
        | Some { Pulse.samples = []; truncated = false } -> ()
        | Some _ | None -> Alcotest.fail "a missing log must seed a known empty pulse");
       write_log (log_path "readable");
       (match seeded "readable" with
        | Some { Pulse.samples = [ { Pulse.at; outcome = Pulse.Turn_ok } ]; _ } ->
          Alcotest.(check (float 0.001)) "turn time" 1794037000.0 at
        | Some _ | None -> Alcotest.fail "a readable log must seed its turns");
       Sys.mkdir (log_path "unreadable-primary") 0o755;
       Alcotest.(check bool)
         "unreadable primary leaves the pulse unseeded"
         true
         (seeded "unreadable-primary" = None);
       write_log (log_path "unreadable-rotated");
       Sys.mkdir (log_path "unreadable-rotated" ^ ".1") 0o755;
       Alcotest.(check bool)
         "unreadable rotated log leaves the pulse unseeded"
         true
         (seeded "unreadable-rotated" = None))
;;

let test_seed_rotation_and_capacity_order () =
  Pulse.reset_for_tests ();
  let base_dir = Filename.temp_dir "keeper-turn-pulse-rot" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       let primary_path =
         Masc.Keeper_types_support.keeper_decision_log_path config "active-keeper"
       in
       let rotated_path = primary_path ^ ".1" in
       let now = 10_000.0 in
       (* Rotated file has 15 older entries: 1000.0 .. 1014.0 *)
       let make_line ts =
         Printf.sprintf {|{"event":"turn","ts_unix":%.1f,"outcome":"success"}|} ts
       in
       Out_channel.with_open_text rotated_path (fun oc ->
         for i = 0 to 14 do
           output_string oc (make_line (1000.0 +. float_of_int i) ^ "\n")
         done);
       (* Primary file has 15 newer entries: 1015.0 .. 1029.0 *)
       Out_channel.with_open_text primary_path (fun oc ->
         for i = 15 to 29 do
           output_string oc (make_line (1000.0 +. float_of_int i) ^ "\n")
         done);
       Pulse.seed_from_decision_log ~now ~config ~keeper_name:"active-keeper" ();
       match Pulse.get ~base_path:config.Masc.Workspace.base_path ~keeper_name:"active-keeper" with
       | None -> Alcotest.fail "expected seeded pulse"
       | Some pulse ->
         Alcotest.(check bool) "pulse is marked truncated" true pulse.truncated;
         Alcotest.(check int) "capacity is 24" 24 (List.length pulse.samples);
         (* First sample must be the newest entry: 1029.0 *)
         let newest = List.hd pulse.samples in
         Alcotest.(check (float 0.001)) "newest sample is preserved" 1029.0 newest.at;
         (* Last sample in 24 must be 1006.0 (surviving older entry) *)
         let last = List.nth pulse.samples 23 in
         Alcotest.(check (float 0.001)) "oldest surviving sample" 1006.0 last.at;
         (* Samples must be strictly descending in time (newest-first) *)
         let is_descending =
           let rec check = function
             | [] | [ _ ] -> true
             | a :: (b :: _ as rest) -> a.Pulse.at > b.Pulse.at && check rest
           in
           check pulse.samples
         in
         Alcotest.(check bool) "samples stored newest-first" true is_descending)
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
        ; Alcotest.test_case
            "seed from decision log read error"
            `Quick
            test_seed_from_decision_log_read_error
        ; Alcotest.test_case "seed rotation and capacity order" `Quick test_seed_rotation_and_capacity_order
        ; Alcotest.test_case "outcome string roundtrip" `Quick test_outcome_string_roundtrip
        ] )
    ]
;;
