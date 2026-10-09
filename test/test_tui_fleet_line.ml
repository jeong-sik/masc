open Alcotest
module Tui_decode = Masc.Tui_decode
module Keeper_fleet_blocker = Masc.Keeper_fleet_blocker

let fleet ?blocker ?(failing = 0) ?(retrying = 0) ?(config_blocked = 0)
    ?(session_recovery = 0) ?(owners_without_fiber = 0) ?(scan_errors = 0) ()
    : Tui_decode.fleet_safety =
  { fs_status = Tui_decode.Fleet_grade Masc.Keeper_fleet_grade.Fleet_ok
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

let test_the_servers_reason_is_drawn_as_text () =
  match
    Masc_tui_fleet_line.freshness_text ~now:1_000.0
      (Tui_decode.Fleet_last_good
         { measured_at_unix = 1_000.0; stale_reason = "x\027[2Jy" })
  with
  | None -> fail "a stale reading drew no tag"
  | Some text -> (
      check bool "no raw escape in the reason" false (String.contains text '\027');
      match
        Masc_tui_fleet_line.freshness_text ~now:0.0
          (Tui_decode.Unrecognised_snapshot_status "x\027[2Jy")
      with
      | None -> fail "an unknown snapshot word drew no tag"
      | Some word ->
          check bool "no raw escape in an unknown word" false
            (String.contains word '\027'))

(* The header's colour came from [String.equal status "ok"], so any word but
   "ok" drew as a warning and nothing named the grades. Only [ok] is healthy;
   a word this build does not know is drawn as written, not as a grade. *)
let test_only_ok_is_healthy () =
  check bool "ok" true
    (Masc_tui_fleet_line.status_is_ok (Tui_decode.Fleet_grade Masc.Keeper_fleet_grade.Fleet_ok));
  check bool "degraded" false
    (Masc_tui_fleet_line.status_is_ok
       (Tui_decode.Fleet_grade Masc.Keeper_fleet_grade.Fleet_degraded));
  check bool "a word this build does not know" false
    (Masc_tui_fleet_line.status_is_ok (Tui_decode.Unrecognised_fleet_status "ok!"))

let test_the_status_word_is_the_grade_or_the_servers_word () =
  check string "a grade" "blocked"
    (Masc_tui_fleet_line.status_text (Tui_decode.Fleet_grade Masc.Keeper_fleet_grade.Fleet_blocked));
  check string "an unknown word as the server wrote it" "held"
    (Masc_tui_fleet_line.status_text (Tui_decode.Unrecognised_fleet_status "held"));
  check bool "with no raw escape in it" false
    (String.contains
       (Masc_tui_fleet_line.status_text
          (Tui_decode.Unrecognised_fleet_status "x\027[2Jy"))
       '\027')

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
    ; ( "not measured"
      , [] )
    ; ( "freshness"
      , [ test_case "the server's reason is drawn as text" `Quick
            test_the_servers_reason_is_drawn_as_text
        ] )
    ; ( "status"
      , [ test_case "only ok is healthy" `Quick test_only_ok_is_healthy
        ; test_case "the status word is the grade or the server's word" `Quick
            test_the_status_word_is_the_grade_or_the_servers_word
        ] )
    ; ( "failing"
      , [] )
    ]
