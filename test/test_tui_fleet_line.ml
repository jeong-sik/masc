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
       List.iter
         (fun ko ->
            check bool (label ^ ": no raw escape") false
              (String.contains (Masc_tui_fleet_line.failure_text ~ko failure) '\027'))
         [ false; true ])
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
    (Masc_tui_fleet_line.status_text ~ko:false Masc.Keeper_fleet_grade.Fleet_blocked)

(* The interval is a setting, so the words convert back to the same seconds:
   a whole unit when one divides it, never a rounded one. *)
let test_an_interval_reads_as_exactly_its_setting () =
  List.iter
    (fun (seconds, expected) ->
       match Masc.Fleet_stream.Proactive_interval.of_seconds seconds with
       | None -> failf "%d seconds is a proactive interval" seconds
       | Some interval ->
         check string (Printf.sprintf "%d seconds" seconds) expected
           (Masc_tui_fleet_line.interval_text interval))
    [ 300, "5m"; 3600, "1h"; 90, "1m30s"; 45, "45s" ]

module Line = Masc_tui_fleet_line

let fleet ~owners ~unread : Masc.Fleet_stream.fleet =
  let interval =
    match Masc.Fleet_stream.Proactive_interval.of_seconds 300 with
    | Some interval -> interval
    | None -> failwith "300 seconds is a proactive interval"
  in
  { Masc.Fleet_stream.fs_status = Masc.Keeper_fleet_grade.Fleet_degraded
  ; fs_blocker = None
  ; fs_operator_action_required = false
  ; fs_bootable_count = 0
  ; fs_running_count = 0
  ; fs_executable_count = 0
  ; fs_failing_count = 0
  ; fs_recovering_count = 0
  ; fs_turn_configuration_error_count = 0
  ; fs_official_client_recovery_required_count = 0
  ; fs_paused_count = 0
  ; fs_target_reaction_capacity = 0
  ; fs_reaction_capacity_shortfall = 0
  ; fs_bootable_names = Masc.Fleet_stream.Names.empty
  ; fs_running_names = Masc.Fleet_stream.Names.empty
  ; fs_executable_names = Masc.Fleet_stream.Names.empty
  ; fs_turn_configuration_error_names = Masc.Fleet_stream.Names.empty
  ; fs_official_client_recovery_required_names = Masc.Fleet_stream.Names.empty
  ; fs_active_task_owner_without_fiber_count = owners
  ; fs_completion_authority_pending_count = 0
  ; fs_active_task_owner_scan_error_count = unread
  ; fs_proactive_interval = interval
  }

let pp_owner_count ppf = function
  | Line.Exactly owners -> Format.fprintf ppf "exactly %d" owners
  | Line.At_least { owners; unread } ->
      Format.fprintf ppf "at least %d (%d sources unread)" owners unread

(* The count is private to the module, so a case says what it expects in a
   shape of its own and the check reads the module's value into it. *)
let owner_count =
  testable
    (fun ppf -> function
       | `Exactly owners -> Format.fprintf ppf "exactly %d" owners
       | `At_least (owners, unread) ->
           Format.fprintf ppf "at least %d (%d sources unread)" owners unread)
    ( = )

let shape = function
  | Line.Exactly owners -> `Exactly owners
  | Line.At_least { owners; unread } -> `At_least (owners, unread)

(* A zero over a complete scan says nothing; a count over one is exact; any
   unread source makes the count a lower bound, a zero included, since the
   unread sources held whatever they held. *)
let test_the_owner_count_is_a_lower_bound_while_sources_are_unread () =
  List.iter
    (fun (label, owners, unread, expected) ->
       check (option owner_count) label expected
         (Option.map shape (Line.owner_count (fleet ~owners ~unread))))
    [ "nothing found, all read", 0, 0, None
    ; "found, all read", 5, 0, Some (`Exactly 5)
    ; "found, some unread", 5, 2, Some (`At_least (5, 2))
    ; "none found, some unread", 0, 2, Some (`At_least (0, 2))
    ]

(* What a cause row says, read from its constructor rather than its words. *)
type fact =
  | Says_blocker of Keeper_fleet_blocker.t
  | Says_owner_count of Line.owner_count

let pp_fact ppf = function
  | Says_blocker blocker ->
      Format.fprintf ppf "blocker %s" (Keeper_fleet_blocker.wire_name blocker)
  | Says_owner_count count -> Format.fprintf ppf "owners %a" pp_owner_count count

let fact = testable pp_fact ( = )

let facts_of_row = function
  | Line.Blocker_alone blocker -> [ Says_blocker blocker ]
  | Line.Blocker_with_owners count ->
      [ Says_blocker Keeper_fleet_blocker.Active_task_owner_without_executable_fiber
      ; Says_owner_count count
      ]
  | Line.Owners_alone count -> [ Says_owner_count count ]

let blockers =
  ("no blocker", None)
  :: List.map
       (fun blocker -> (Keeper_fleet_blocker.wire_name blocker, Some blocker))
       Keeper_fleet_blocker.all

let owner_readings =
  [ ("no owner count", Line.owner_count (fleet ~owners:0 ~unread:0))
  ; ("a count", Line.owner_count (fleet ~owners:5 ~unread:0))
  ; ("a count with unread sources", Line.owner_count (fleet ~owners:5 ~unread:2))
  ]

(* The capacity card drew the task-owner blocker's phrase and then the same
   phrase with the owner count, one fact on two rows. For every blocker and
   every owner reading the rows carry the blocker and the count that were
   read, and each of them once: the sorted facts equal the sorted readings,
   so a fact said twice shows as an extra entry. *)
let test_the_cause_rows_say_each_fact_once () =
  List.iter
    (fun (blocker_label, blocker) ->
       List.iter
         (fun (owner_label, owners) ->
            let said =
              List.concat_map facts_of_row (Line.cause_rows ~blocker owners)
            in
            let read =
              Option.to_list (Option.map (fun b -> Says_blocker b) blocker)
              @ Option.to_list (Option.map (fun c -> Says_owner_count c) owners)
            in
            check (list fact)
              (blocker_label ^ " with " ^ owner_label)
              (List.sort compare read) (List.sort compare said))
         owner_readings)
    blockers

(* The facts alone do not tell one row from two: the task-owner blocker and
   its count must share a row, and any other blocker keeps its count on a
   row of its own. With each fact said once, a shared row leaves no other
   row for either. *)
let test_only_the_task_owner_blocker_shares_a_row_with_the_count () =
  List.iter
    (fun (blocker_label, blocker) ->
       List.iter
         (fun (owner_label, owners) ->
            let label = blocker_label ^ " with " ^ owner_label in
            let rows = Line.cause_rows ~blocker owners in
            let shared =
              List.exists
                (function
                  | Line.Blocker_with_owners _ -> true
                  | Line.Blocker_alone _ | Line.Owners_alone _ -> false)
                rows
            in
            let expected_shared =
              match blocker, owners with
              | Some Keeper_fleet_blocker.Active_task_owner_without_executable_fiber, Some _ ->
                  true
              | ( Some
                    Keeper_fleet_blocker.(
                      Keeper_bootstrap_disabled | No_executable_keeper_fibers
                      | Turn_configuration_error | Official_client_recovery_required
                      | Reaction_capacity_below_target
                      | Active_task_owner_without_executable_fiber
                      | Durable_paused_autoboot_enabled)
                , (None | Some _) )
              | None, (None | Some _) ->
                  false
            in
            check bool label expected_shared shared)
         owner_readings)
    blockers

(* What a retained row says, read from its constructor. *)
type retained_fact =
  | Says_stale
  | Says_trouble
  | Says_identity_unconfirmed

let retained_fact =
  testable
    (fun ppf fact ->
       Format.pp_print_string ppf
         (match fact with
          | Says_stale -> "stale"
          | Says_trouble -> "trouble"
          | Says_identity_unconfirmed -> "identity unconfirmed"))
    ( = )

let facts_of_retained_row = function
  | Line.Stale_with_trouble _ -> [ Says_stale; Says_trouble ]
  | Line.Stale_with_identity_unconfirmed -> [ Says_stale; Says_identity_unconfirmed ]
  | Line.Identity_unconfirmed_too -> [ Says_identity_unconfirmed ]

(* The capacity card said "stale, current capacity unknown" on its first row
   and the reason, the unconfirmed workspace identity, on a row below the
   meters: one fact on two rows. For every trouble and identity reading the
   rows say "stale" once when the reading is retained, never otherwise, and
   each reason once; and the first row is the one that says "stale". *)
let test_the_retained_rows_say_stale_once_with_why () =
  let troubles =
    [ ("no trouble", None)
    ; ( "scans failing"
      , Some
          (Masc_tui_fleet_stream.Scans_failing
             { Masc.Fleet_stream.since = 0.; reason = Masc.Fleet_stream.Scan_failed }) )
    ; ("stream lost", Some (Masc_tui_fleet_stream.Disconnected { since = 0. }))
    ]
  in
  List.iter
    (fun (trouble_label, trouble) ->
       List.iter
         (fun identity_confirmed ->
            let label =
              trouble_label ^ if identity_confirmed then ", identity confirmed"
                else ", identity unconfirmed"
            in
            let rows = Line.retained_rows ~trouble ~identity_confirmed in
            let said = List.concat_map facts_of_retained_row rows in
            let reasons =
              Option.to_list (Option.map (fun _ -> Says_trouble) trouble)
              @ if identity_confirmed then [] else [ Says_identity_unconfirmed ]
            in
            let read = if reasons = [] then [] else Says_stale :: reasons in
            check (list retained_fact) label (List.sort compare read)
              (List.sort compare said);
            check bool (label ^ ": the first row says stale") true
              (match rows with
               | [] -> reasons = []
               | (Line.Stale_with_trouble _ | Line.Stale_with_identity_unconfirmed) :: _ -> true
               | Line.Identity_unconfirmed_too :: _ -> false))
         [ true; false ])
    troubles

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
      , [ test_case "the owner count is a lower bound while sources are unread" `Quick
            test_the_owner_count_is_a_lower_bound_while_sources_are_unread
        ; test_case "the cause rows say each fact once" `Quick
            test_the_cause_rows_say_each_fact_once
        ; test_case "only the task-owner blocker shares a row with the count" `Quick
            test_only_the_task_owner_blocker_shares_a_row_with_the_count
        ; test_case "the retained rows say stale once, with why" `Quick
            test_the_retained_rows_say_stale_once_with_why
        ] )
    ; ( "server words"
      , [ test_case "the server's words are drawn as text" `Quick
            test_the_servers_words_are_drawn_as_text
        ] )
    ; ( "status"
      , [ test_case "only ok is healthy" `Quick test_only_ok_is_healthy
        ; test_case "the status word is the grade's wire name" `Quick
            test_the_status_word_is_the_grades_wire_name
        ] )
    ; ( "proactive interval"
      , [ test_case "an interval reads as exactly its setting" `Quick
            test_an_interval_reads_as_exactly_its_setting
        ] )
    ; ( "failing"
      , [] )
    ]
