module Pulse = Masc.Keeper_turn_pulse

(* A slot boundary well inside the Unix era, so every [at] below is positive. *)
let base = 1_794_000_600

let at_slot ?(offset = 0) slot = float_of_int (base + (slot * Pulse.slot_seconds) + offset)

let tallies (pulse : Pulse.pulse) =
  List.map
    (fun ({ starts_at; tally = { ok; rested; failed } } : Pulse.slot) ->
      starts_at, ok, rested, failed)
    pulse.slots
;;

let tally_list = Alcotest.(list (pair int (triple int int int)))
let flat = List.map (fun (s, ok, rested, failed) -> s, (ok, rested, failed))

let get_exn ~base_path ~keeper_name =
  match Pulse.get ~base_path ~keeper_name with
  | Some pulse -> pulse
  | None -> Alcotest.fail "expected a pulse"
;;

let test_unknown_keeper_has_no_pulse () =
  Pulse.reset_for_tests ();
  Alcotest.(check bool)
    "unknown keeper has no pulse"
    true
    (Pulse.get ~base_path:"/tmp/p1" ~keeper_name:"k1" = None)
;;

let test_turns_are_counted_in_their_half_hour () =
  Pulse.reset_for_tests ();
  let record at outcome = Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"alpha" ~at outcome in
  record (at_slot ~offset:10 0) Pulse.Turn_ok;
  record (at_slot ~offset:1799 0) Pulse.Turn_failed;
  record (at_slot 1) Pulse.Turn_rested;
  record (at_slot ~offset:5 1) Pulse.Turn_ok;
  let pulse = get_exn ~base_path:"/tmp/p1" ~keeper_name:"alpha" in
  Alcotest.(check (float 0.001)) "known from the first turn" (at_slot ~offset:10 0) pulse.known_since;
  Alcotest.check
    tally_list
    "newest slot first, counted by outcome"
    (flat [ base + Pulse.slot_seconds, 1, 1, 0; base, 1, 0, 1 ])
    (flat (tallies pulse))
;;

let test_many_turns_keep_every_hour () =
  Pulse.reset_for_tests ();
  (* 360 turns over 12 hours: the old 24-turn cap held 48 minutes of them. *)
  for i = 0 to 359 do
    Pulse.record
      ~base_path:"/tmp/p1"
      ~keeper_name:"busy"
      ~at:(at_slot ~offset:(i * 120) 0)
      Pulse.Turn_ok
  done;
  let pulse = get_exn ~base_path:"/tmp/p1" ~keeper_name:"busy" in
  Alcotest.(check int) "24 half-hour slots" 24 (List.length pulse.slots);
  Alcotest.(check int)
    "every turn counted"
    360
    (List.fold_left (fun sum (slot : Pulse.slot) -> sum + slot.tally.ok) 0 pulse.slots)
;;

let test_a_turn_prunes_slots_older_than_a_day () =
  Pulse.reset_for_tests ();
  let record slot = Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"k" ~at:(at_slot slot) Pulse.Turn_ok in
  let slots_per_day = Pulse.window_seconds / Pulse.slot_seconds in
  record 0;
  record 1;
  record (slots_per_day + 1);
  let pulse = get_exn ~base_path:"/tmp/p1" ~keeper_name:"k" in
  Alcotest.(check (list int))
    "the slot a day before the newest stays, the one before it goes"
    [ base + ((slots_per_day + 1) * Pulse.slot_seconds); base + Pulse.slot_seconds ]
    (List.map (fun (slot : Pulse.slot) -> slot.starts_at) pulse.slots)
;;

let test_a_late_turn_lands_in_its_own_slot () =
  Pulse.reset_for_tests ();
  let record slot = Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"k" ~at:(at_slot slot) Pulse.Turn_ok in
  record 3;
  record 1;
  record 2;
  let pulse = get_exn ~base_path:"/tmp/p1" ~keeper_name:"k" in
  Alcotest.(check (list int))
    "newest first"
    [ 3; 2; 1 ]
    (List.map (fun (slot : Pulse.slot) -> (slot.starts_at - base) / Pulse.slot_seconds) pulse.slots)
;;

let test_pulses_are_kept_per_workspace_and_keeper () =
  Pulse.reset_for_tests ();
  Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"k1" ~at:(at_slot 0) Pulse.Turn_ok;
  Pulse.record ~base_path:"/tmp/p2" ~keeper_name:"k1" ~at:(at_slot 1) Pulse.Turn_failed;
  Pulse.record ~base_path:"/tmp/p1" ~keeper_name:"k2" ~at:(at_slot 2) Pulse.Turn_rested;
  let newest ~base_path ~keeper_name =
    match (get_exn ~base_path ~keeper_name).slots with
    | slot :: _ -> slot.starts_at
    | [] -> Alcotest.fail "expected a slot"
  in
  Alcotest.(check int) "p1 k1" base (newest ~base_path:"/tmp/p1" ~keeper_name:"k1");
  Alcotest.(check int) "p2 k1" (base + Pulse.slot_seconds) (newest ~base_path:"/tmp/p2" ~keeper_name:"k1");
  Alcotest.(check int) "p1 k2" (base + (2 * Pulse.slot_seconds)) (newest ~base_path:"/tmp/p1" ~keeper_name:"k2")
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
   | Some s -> Alcotest.(check bool) "outcome failed" true (s.outcome = Pulse.Turn_failed));
  let non_turn = {|{"event":"heartbeat","ts_unix":1794035000.0,"outcome":"success"}|} in
  Alcotest.(check bool) "ignore non-turn" true (Pulse.sample_of_decision_line non_turn = None);
  Alcotest.(check bool) "ignore bad json" true (Pulse.sample_of_decision_line "not json" = None)
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

let turn_line at = Printf.sprintf {|{"event":"turn","ts_unix":%.1f,"outcome":"success"}|} at

let write_turns path ats =
  Out_channel.with_open_text path (fun oc ->
    List.iter (fun at -> output_string oc (turn_line at ^ "\n")) ats)
;;

let with_workspace f =
  Pulse.reset_for_tests ();
  let base_dir = Filename.temp_dir "keeper-turn-pulse-seed" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree base_dir)
    (fun () ->
       let config = Masc.Workspace.default_config base_dir in
       let log_path keeper_name =
         Masc.Keeper_types_support.keeper_decision_log_path config keeper_name
       in
       f config log_path)
;;

let now = at_slot 100
let window_start = now -. float_of_int Pulse.window_seconds

let seeded config keeper_name =
  Pulse.seed_from_decision_log ~now ~config ~keeper_name ();
  Pulse.get ~base_path:config.Masc.Workspace.base_path ~keeper_name
;;

let check_known label expected = function
  | Some (pulse : Pulse.pulse) -> Alcotest.(check (float 0.001)) label expected pulse.known_since
  | None -> Alcotest.fail (label ^ ": expected a seeded pulse")
;;

(* A directory in place of a decision log exists, so the file-exists check
   passes, and every read of it fails. That is a log the pulse cannot read, as
   opposed to a log that is missing or holds no turns. *)
let test_seed_reads_what_the_logs_can_tell () =
  with_workspace (fun config log_path ->
    check_known "a missing log knows the whole window" window_start (seeded config "no-log");
    write_turns (log_path "whole") [ at_slot 90; at_slot 95 ];
    let whole = seeded config "whole" in
    check_known "a whole log with no rotation knows the whole window" window_start whole;
    Alcotest.(check int) "its turns are slotted" 2 (List.length (Option.get whole).slots);
    write_turns (log_path "rotated-reaches" ^ ".1") [ window_start -. 60.0; at_slot 80 ];
    write_turns (log_path "rotated-reaches") [ at_slot 90 ];
    check_known
      "a rotated log that reaches the window start knows the window"
      window_start
      (seeded config "rotated-reaches");
    write_turns (log_path "rotated-inside" ^ ".1") [ at_slot 70; at_slot 80 ];
    write_turns (log_path "rotated-inside") [ at_slot 90 ];
    check_known
      "rotation dropped what came before the rotated log"
      (at_slot 70)
      (seeded config "rotated-inside");
    Sys.mkdir (log_path "unreadable-primary") 0o755;
    Alcotest.(check bool)
      "unreadable primary leaves the pulse unseeded"
      true
      (seeded config "unreadable-primary" = None);
    write_turns (log_path "unreadable-rotated") [ at_slot 90 ];
    Sys.mkdir (log_path "unreadable-rotated" ^ ".1") 0o755;
    Alcotest.(check bool)
      "unreadable rotated log leaves the pulse unseeded"
      true
      (seeded config "unreadable-rotated" = None))
;;

let test_seed_leaves_a_recorded_keeper_alone () =
  with_workspace (fun config log_path ->
    let base_path = config.Masc.Workspace.base_path in
    Pulse.record ~base_path ~keeper_name:"live" ~at:(at_slot 99) Pulse.Turn_failed;
    write_turns (log_path "live") [ at_slot 90 ];
    check_known "the recorded pulse stays" (at_slot 99) (seeded config "live"))
;;

let () =
  Alcotest.run
    "keeper_turn_pulse"
    [ ( "store"
      , [ Alcotest.test_case "unknown keeper has no pulse" `Quick test_unknown_keeper_has_no_pulse
        ; Alcotest.test_case "turns are counted in their half hour" `Quick
            test_turns_are_counted_in_their_half_hour
        ; Alcotest.test_case "many turns keep every hour" `Quick test_many_turns_keep_every_hour
        ; Alcotest.test_case "a turn prunes slots older than a day" `Quick
            test_a_turn_prunes_slots_older_than_a_day
        ; Alcotest.test_case "a late turn lands in its own slot" `Quick
            test_a_late_turn_lands_in_its_own_slot
        ; Alcotest.test_case "pulses are kept per workspace and keeper" `Quick
            test_pulses_are_kept_per_workspace_and_keeper
        ] )
    ; ( "seed"
      , [ Alcotest.test_case "sample of decision line" `Quick test_sample_of_decision_line
        ; Alcotest.test_case "seed reads what the logs can tell" `Quick
            test_seed_reads_what_the_logs_can_tell
        ; Alcotest.test_case "seed leaves a recorded keeper alone" `Quick
            test_seed_leaves_a_recorded_keeper_alone
        ] )
    ]
;;
