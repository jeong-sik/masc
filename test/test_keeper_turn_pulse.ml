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
    (List.map (fun (slot : Pulse.slot) -> slot.starts_at) pulse.slots);
  Alcotest.(check (float 0.001))
    "known_since moves up to the pruned boundary"
    (float_of_int (base + Pulse.slot_seconds))
    pulse.known_since
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
  let line ?(path = {|,"execution_path":"autonomous_cycle"|}) ~event ~ts ~outcome () =
    Printf.sprintf {|{"event":"%s","ts_unix":%.1f,"outcome":"%s"%s}|} event ts outcome path
  in
  (match Pulse.sample_of_decision_line (line ~event:"turn" ~ts:1794037335.0 ~outcome:"success" ()) with
   | None -> Alcotest.fail "expected sample"
   | Some s ->
     Alcotest.(check (float 0.001)) "ts" 1794037335.0 s.at;
     Alcotest.(check bool) "outcome ok" true (s.outcome = Pulse.Turn_ok));
  (match Pulse.sample_of_decision_line (line ~event:"turn" ~ts:1794036000.0 ~outcome:"error" ()) with
   | None -> Alcotest.fail "expected sample"
   | Some s -> Alcotest.(check bool) "outcome failed" true (s.outcome = Pulse.Turn_failed));
  let ignored label raw = Alcotest.(check bool) label true (Pulse.sample_of_decision_line raw = None) in
  ignored "ignore non-turn" (line ~event:"heartbeat" ~ts:1794035000.0 ~outcome:"success" ());
  ignored
    "ignore a chat turn"
    (line ~path:{|,"execution_path":"direct_turn"|} ~event:"turn" ~ts:1794035000.0 ~outcome:"success" ());
  ignored "ignore a turn with no path" (line ~path:"" ~event:"turn" ~ts:1794035000.0 ~outcome:"success" ());
  ignored "ignore bad json" "not json"
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

let turn_line at =
  Printf.sprintf
    {|{"event":"turn","ts_unix":%.1f,"outcome":"success","execution_path":"autonomous_cycle"}|}
    at
;;

let chat_line at =
  Printf.sprintf
    {|{"event":"turn","ts_unix":%.1f,"outcome":"success","execution_path":"direct_turn"}|}
    at
;;

let write_lines path lines =
  Out_channel.with_open_text path (fun oc ->
    List.iter (fun line -> output_string oc (line ^ "\n")) lines)
;;

let write_turns path ats = write_lines path (List.map turn_line ats)

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
    check_known "a keeper with no log is known from now" now (seeded config "no-log");
    write_turns (log_path "whole") [ at_slot 90; at_slot 95 ];
    let whole = seeded config "whole" in
    check_known "a whole log with no rotation is known from its first row" (at_slot 90) whole;
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

let slot_count = function
  | Some (pulse : Pulse.pulse) -> List.length pulse.slots
  | None -> Alcotest.fail "expected a seeded pulse"
;;

let test_seed_reads_the_primary_log_alone_when_it_reaches_the_window () =
  with_workspace (fun config log_path ->
    write_turns (log_path "reaches") [ window_start -. 60.0; at_slot 90 ];
    let reaches = seeded config "reaches" in
    check_known "a primary log that reaches the window start knows the window" window_start reaches;
    Alcotest.(check int) "the turn before the window is not slotted" 1 (slot_count reaches))
;;

let test_seed_reads_the_rotated_log_when_the_primary_is_missing () =
  with_workspace (fun config log_path ->
    write_turns (log_path "lone-rotated" ^ ".1") [ at_slot 70; at_slot 80 ];
    let lone = seeded config "lone-rotated" in
    check_known "a lone rotated log is known from its oldest turn" (at_slot 70) lone;
    Alcotest.(check int) "its turns are slotted" 2 (slot_count lone))
;;

(* A chat row is not a pulse turn, but it shows how far back the log reaches. *)
let test_seed_knows_the_log_from_rows_of_any_event () =
  with_workspace (fun config log_path ->
    write_lines (log_path "chat-before") [ chat_line (window_start -. 60.0); turn_line (at_slot 90) ];
    let before = seeded config "chat-before" in
    check_known "a chat row older than the window reaches the window" window_start before;
    Alcotest.(check int) "only the autonomous turn is slotted" 1 (slot_count before);
    write_lines (log_path "chat-inside") [ chat_line (at_slot 85); turn_line (at_slot 90) ];
    check_known "a chat row is the log's first row" (at_slot 85) (seeded config "chat-inside"))
;;

let test_seed_drops_turns_stamped_after_now () =
  with_workspace (fun config log_path ->
    write_turns (log_path "skewed") [ at_slot 90; now +. 600.0 ];
    match seeded config "skewed" with
    | Some { slots = [ only ]; _ } ->
      Alcotest.(check int) "only the past turn is slotted" (Pulse.slot_start (at_slot 90)) only.starts_at
    | Some _ | None -> Alcotest.fail "expected one slot")
;;

(* The reader keeps the last 10,000 lines, so the oldest turns of a long log
   are not read and the pulse is known only from the oldest one that was. *)
let test_seed_knows_a_long_log_from_its_oldest_read_turn () =
  with_workspace (fun config log_path ->
    let first = window_start +. 60.0 in
    let lines = 10_050 in
    write_turns (log_path "long") (List.init lines (fun i -> first +. float_of_int i));
    check_known
      "known from the oldest turn the bounded read kept"
      (first +. float_of_int (lines - 10_000))
      (seeded config "long"))
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
        ; Alcotest.test_case "seed reads the primary log alone when it reaches the window" `Quick
            test_seed_reads_the_primary_log_alone_when_it_reaches_the_window
        ; Alcotest.test_case "seed reads the rotated log when the primary is missing" `Quick
            test_seed_reads_the_rotated_log_when_the_primary_is_missing
        ; Alcotest.test_case "seed knows the log from rows of any event" `Quick
            test_seed_knows_the_log_from_rows_of_any_event
        ; Alcotest.test_case "seed drops turns stamped after now" `Quick
            test_seed_drops_turns_stamped_after_now
        ; Alcotest.test_case "seed knows a long log from its oldest read turn" `Quick
            test_seed_knows_a_long_log_from_its_oldest_read_turn
        ; Alcotest.test_case "seed leaves a recorded keeper alone" `Quick
            test_seed_leaves_a_recorded_keeper_alone
        ] )
    ]
;;
