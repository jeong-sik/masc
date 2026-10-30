open Alcotest
module Keeper_fleet_blocker = Masc.Keeper_fleet_blocker

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

(* The refusal body and a rejected frame's detail are the server's words, drawn
   on the Keepers screen, so an escape sequence in them must not reach the
   terminal. *)
let test_the_servers_words_are_drawn_as_text () =
  let hostile = "x\027[2Jy" in
  List.iter
    (fun (label, failure) ->
       check bool (label ^ ": no raw escape") false
         (String.contains (Masc_tui_fleet_line.failure_text failure) '\027'))
    [ "a refusal", Masc_tui_fleet_stream.Refused { status = 500; detail = hostile }
    ; "a rejected frame", Masc_tui_fleet_stream.Frame_rejected hostile
    ]

(* The header's colour came from [String.equal status "ok"], so any word but
   "ok" drew as a warning and nothing named the grades. Only [ok] is healthy. *)
let test_only_ok_is_healthy () =
  check bool "ok" true (Masc_tui_fleet_line.status_is_ok Masc.Keeper_fleet_grade.Fleet_ok);
  check bool "degraded" false
    (Masc_tui_fleet_line.status_is_ok Masc.Keeper_fleet_grade.Fleet_degraded);
  check bool "blocked" false
    (Masc_tui_fleet_line.status_is_ok Masc.Keeper_fleet_grade.Fleet_blocked)

let test_the_status_word_is_the_grades_wire_name () =
  check string "a grade" "blocked"
    (Masc_tui_fleet_line.status_text Masc.Keeper_fleet_grade.Fleet_blocked)

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
      , [] )
    ; ( "task owner scan"
      , [] )
    ; ( "server words"
      , [ test_case "the server's words are drawn as text" `Quick
            test_the_servers_words_are_drawn_as_text
        ] )
    ; ( "status"
      , [ test_case "only ok is healthy" `Quick test_only_ok_is_healthy
        ; test_case "the status word is the grade's wire name" `Quick
            test_the_status_word_is_the_grades_wire_name
        ] )
    ; ( "failing"
      , [] )
    ]
