open Alcotest
module Tui_decode = Masc.Tui_decode
module Keeper_fleet_blocker = Masc.Keeper_fleet_blocker

let contains needle text =
  let text_length = String.length text in
  let needle_length = String.length needle in
  let rec walk index =
    if index + needle_length > text_length then false
    else if String.sub text index needle_length = needle then true
    else walk (index + 1)
  in
  walk 0

let fleet ?blocker ?(failing = 0) ?(retrying = 0) ?(config_blocked = 0)
    ?(session_recovery = 0) ?(owners_without_fiber = 0) ?(scan_errors = 0) ()
    : Tui_decode.fleet_safety =
  { fs_status = "ok"
  ; fs_blocker = blocker
  ; fs_operator_action_required = false
  ; fs_bootable_count = 12
  ; fs_running_count = 11
  ; fs_executable_count = 12
  ; fs_failing_count = failing
  ; fs_recovering_count = retrying
  ; fs_turn_configuration_error_count = config_blocked
  ; fs_official_client_recovery_required_count = session_recovery
  ; fs_paused_count = 3
  ; fs_target_reaction_capacity = 12
  ; fs_reaction_capacity_shortfall = 0
  ; fs_bootable_names = []
  ; fs_running_names = []
  ; fs_executable_names = []
  ; fs_turn_configuration_error_names = []
  ; fs_official_client_recovery_required_names = []
  ; fs_active_task_owner_without_fiber_count = owners_without_fiber
  ; fs_completion_authority_pending_count = 0
  ; fs_active_task_owner_scan_error_count = scan_errors
  }

let known blocker = Tui_decode.Blocker blocker
let blocker_text = Masc_tui_fleet_line.blocker_text
let failing_text = Masc_tui_fleet_line.failing_text

(* The fleet scan and the TUI read one list, so a name the server writes is a
   name the TUI reads back as the same reason. *)
let test_every_blocker_reads_back_from_its_wire_name () =
  List.iter
    (fun blocker ->
      let name = Keeper_fleet_blocker.wire_name blocker in
      check bool (name ^ " reads back") true
        (Keeper_fleet_blocker.of_wire_name name = Some blocker))
    Keeper_fleet_blocker.all

let test_no_two_blockers_share_a_wire_name () =
  let names = List.map Keeper_fleet_blocker.wire_name Keeper_fleet_blocker.all in
  check int "one name per reason" (List.length names)
    (List.length (List.sort_uniq String.compare names))

(* These spellings are the /health contract. The type decides who spells
   them, not what they are. *)
let test_the_wire_names_are_the_fleet_scans () =
  check (list string) "the fleet scan's blocker names"
    [ "keeper_bootstrap_disabled"
    ; "no_executable_keeper_fibers"
    ; "turn_configuration_error"
    ; "official_client_recovery_required"
    ; "reaction_capacity_below_target"
    ; "active_task_owner_without_executable_fiber"
    ; "durable_paused_autoboot_enabled"
    ]
    (List.map Keeper_fleet_blocker.wire_name Keeper_fleet_blocker.all)

(* The counts line below says [paused 3]; the header names the reason in the
   same words and leaves the number to that line. *)
let test_a_blocker_is_named_in_the_counts_lines_words () =
  check (option string) "a durable pause" (Some "autoboot keepers paused")
    (blocker_text
       (fleet ~blocker:(known Keeper_fleet_blocker.Durable_paused_autoboot_enabled)
          ()));
  check (option string) "a configuration error" (Some "config-blocked keepers")
    (blocker_text
       (fleet ~blocker:(known Keeper_fleet_blocker.Turn_configuration_error)
          ~failing:1 ~config_blocked:1 ()))

(* Every reason is said in words, and no two reasons say the same thing. *)
let test_every_known_blocker_is_said_in_words () =
  let texts =
    List.map
      (fun blocker ->
        let name = Keeper_fleet_blocker.wire_name blocker in
        match blocker_text (fleet ~blocker:(known blocker) ()) with
        | None -> fail (name ^ " drew nothing")
        | Some text ->
            check bool
              (Printf.sprintf "%S is not the identifier %s" text name)
              false
              (String.contains text '_');
            text)
      Keeper_fleet_blocker.all
  in
  check int "one phrase per reason" (List.length texts)
    (List.length (List.sort_uniq String.compare texts))

let test_an_unknown_blocker_is_drawn_by_name () =
  check (option string) "the server's own name"
    (Some "blocker: lane_capacity_withdrawn")
    (blocker_text
       (fleet ~blocker:(Tui_decode.Unrecognised_blocker "lane_capacity_withdrawn")
          ()))

let test_no_blocker_draws_nothing () =
  check (option string) "no blocker" None (blocker_text (fleet ()))

(* A class that holds no failing Keeper says nothing about this fleet. *)
let test_failing_names_only_the_classes_that_hold_a_keeper () =
  check (option string) "one class" (Some "failing 2 (retrying 2)")
    (failing_text (fleet ~failing:2 ~retrying:2 ()));
  check (option string) "two classes"
    (Some "failing 3 (retrying 1 \xc2\xb7 session-recovery-required 2)")
    (failing_text (fleet ~failing:3 ~retrying:1 ~session_recovery:2 ()))

let test_nothing_failing_draws_nothing () =
  check (option string) "no failing" None (failing_text (fleet ()))

let owner_scan_text = Masc_tui_fleet_line.owner_scan_text

(* A Keeper whose profile does not load is a scan error: its tasks are left out
   of the owner count, and only a backlog failure moves the fleet status off
   "ok". So an unread source has to be said beside the count it shortened, or
   the row reports a complete reading it never made. *)
let test_an_unread_source_is_named_beside_the_count () =
  check (option string) "the count and what it is missing"
    (Some "task owner without fiber 0+ (2 sources unread)")
    (owner_scan_text (fleet ~scan_errors:2 ()));
  check (option string) "one source reads as one"
    (Some "task owner without fiber 3+ (1 source unread)")
    (owner_scan_text (fleet ~owners_without_fiber:3 ~scan_errors:1 ()))

(* The number a shortened scan reports is a lower bound, so it never stands as
   a total. Without the [+], a scan that read nothing says "0", which reads as
   "there are none" -- the one reading the unread sources rule out. *)
let test_a_shortened_count_is_a_lower_bound () =
  List.iter
    (fun (owners, scan_errors) ->
      let drawn =
        match owner_scan_text (fleet ~owners_without_fiber:owners ~scan_errors ())
        with
        | Some text -> text
        | None -> Alcotest.fail "a scan with an unread source draws a row"
      in
      check bool
        (Printf.sprintf "%S states its number as a lower bound" drawn)
        true
        (contains (Printf.sprintf "fiber %d+ (" owners) drawn))
    [ (0, 2); (3, 1); (12, 7) ]

let test_a_complete_scan_says_only_the_count () =
  check (option string) "nothing to qualify"
    (Some "task owner without fiber 3")
    (owner_scan_text (fleet ~owners_without_fiber:3 ()))

(* Zero over a complete reading is a row spent saying nothing happened. *)
let test_nothing_found_and_nothing_missed_draws_nothing () =
  check (option string) "no row" None (owner_scan_text (fleet ()))

(* While the health snapshot is rebuilt the server sends no counts, so the
   line says the fleet was not measured yet and names the placeholder's word,
   instead of drawing an idle fleet from zeros. *)
let test_an_unmeasured_fleet_says_why () =
  check string "a warming snapshot" "not measured yet (warming)"
    (Masc_tui_fleet_line.not_measured_text ~status:"warming")

let () =
  run "tui fleet line"
    [ ( "blocker names"
      , [ test_case "every blocker reads back from its wire name" `Quick
            test_every_blocker_reads_back_from_its_wire_name
        ; test_case "no two blockers share a wire name" `Quick
            test_no_two_blockers_share_a_wire_name
        ; test_case "the wire names are the fleet scan's" `Quick
            test_the_wire_names_are_the_fleet_scans
        ] )
    ; ( "blocker words"
      , [ test_case "a blocker is named in the counts line's words" `Quick
            test_a_blocker_is_named_in_the_counts_lines_words
        ; test_case "every known blocker is said in words" `Quick
            test_every_known_blocker_is_said_in_words
        ; test_case "an unknown blocker is drawn by name" `Quick
            test_an_unknown_blocker_is_drawn_by_name
        ; test_case "no blocker draws nothing" `Quick
            test_no_blocker_draws_nothing
        ] )
    ; ( "task owner scan"
      , [ test_case "an unread source is named beside the count" `Quick
            test_an_unread_source_is_named_beside_the_count
        ; test_case "a shortened count is a lower bound" `Quick
            test_a_shortened_count_is_a_lower_bound
        ; test_case "a complete scan says only the count" `Quick
            test_a_complete_scan_says_only_the_count
        ; test_case "nothing found and nothing missed draws nothing" `Quick
            test_nothing_found_and_nothing_missed_draws_nothing
        ] )
    ; ( "not measured"
      , [ test_case "an unmeasured fleet says why" `Quick
            test_an_unmeasured_fleet_says_why
        ] )
    ; ( "failing"
      , [ test_case "names only the classes that hold a keeper" `Quick
            test_failing_names_only_the_classes_that_hold_a_keeper
        ; test_case "nothing failing draws nothing" `Quick
            test_nothing_failing_draws_nothing
        ] )
    ]
