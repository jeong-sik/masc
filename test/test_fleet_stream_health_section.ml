open Alcotest
module F = Masc.Fleet_stream
module Section = Masc.Fleet_stream_health_section
module Grade = Masc.Keeper_fleet_grade
module Blocker = Masc.Keeper_fleet_blocker

let names words = F.Names.of_list words

(* Every field holds a value no other field holds, so a key read into the wrong
   field would give a different reading. *)
let expected : F.fleet =
  { F.fs_status = Grade.Fleet_degraded
  ; fs_blocker = Some Blocker.Turn_configuration_error
  ; fs_operator_action_required = true
  ; fs_bootable_count = 11
  ; fs_running_count = 12
  ; fs_executable_count = 13
  ; fs_failing_count = 14
  ; fs_recovering_count = 15
  ; fs_turn_configuration_error_count = 16
  ; fs_official_client_recovery_required_count = 17
  ; fs_paused_count = 18
  ; fs_target_reaction_capacity = 19
  ; fs_reaction_capacity_shortfall = 20
  ; fs_bootable_names = names [ "alpha"; "beta"; "gamma" ]
  ; fs_running_names = names [ "alpha"; "beta" ]
  ; fs_executable_names = names [ "beta"; "gamma" ]
  ; fs_turn_configuration_error_names = names [ "delta" ]
  ; fs_official_client_recovery_required_names = names [ "epsilon"; "zeta" ]
  ; fs_active_task_owner_without_fiber_count = 21
  ; fs_completion_authority_pending_count = 22
  ; fs_active_task_owner_scan_error_count = 23
  }
;;

let strings words : Yojson.Safe.t = `List (List.map (fun w -> `String w) words)

(* The section as the scan writes it, key by key. The names are the scan's own;
   this table is the check on the one in the module. *)
let section_pairs : (string * Yojson.Safe.t) list =
  [ "schema", `String Blocker.reading_schema
  ; "status", `String "degraded"
  ; "blocker", `String "turn_configuration_error"
  ; "operator_action_required", `Bool true
  ; "bootable_keeper_count", `Int 11
  ; "running_keeper_fiber_count", `Int 12
  ; "executable_keeper_fiber_count", `Int 13
  ; "failing_keeper_fiber_count", `Int 14
  ; "recovering_keeper_fiber_count", `Int 15
  ; "turn_configuration_error_keeper_count", `Int 16
  ; "official_client_recovery_required_keeper_count", `Int 17
  ; "paused_keeper_count", `Int 18
  ; "target_reaction_capacity_count", `Int 19
  ; "reaction_capacity_shortfall_count", `Int 20
  ; "bootable_keeper_names", strings [ "alpha"; "beta"; "gamma" ]
  ; "running_keeper_names", strings [ "alpha"; "beta" ]
  ; "executable_keeper_names", strings [ "beta"; "gamma" ]
  ; "turn_configuration_error_keeper_names", strings [ "delta" ]
  ; "official_client_recovery_required_keeper_names", strings [ "epsilon"; "zeta" ]
  ; "active_task_owner_without_executable_fiber_count", `Int 21
  ; "completion_authority_pending_task_count", `Int 22
  ; "active_task_owner_scan_error_count", `Int 23
  ]
;;

(* Fields the scan writes for other readers; this reader must ignore them. *)
let noise : (string * Yojson.Safe.t) list =
  [ "active_task_owner_fiber_scan_semantics", `String "..."
  ; "completion_authority_pending_tasks", `List [ `Assoc [ "id", `String "t" ] ]
  ; "autoboot_enabled_keeper_names", strings [ "alpha" ]
  ]
;;

let health ?(pairs = section_pairs) () : (string * Yojson.Safe.t) list =
  [ "overall_status", `String "ok"; "keeper_fleet_safety", `Assoc (pairs @ noise) ]
;;

let without key pairs = List.filter (fun (name, _) -> not (String.equal name key)) pairs

let replacing key value pairs =
  List.map (fun (name, old) -> if String.equal name key then name, value else name, old) pairs
;;

let is_unreadable = function
  | Error (Section.Unreadable _) -> true
  | Error (Section.Not_measured _ | Section.Scan_failed _) | Ok _ -> false
;;

let fleet_t = testable (fun fmt _ -> Format.pp_print_string fmt "<fleet>") F.equal_fleet

let test_every_key_is_read_into_its_own_field () =
  match Section.fleet_of_health_fields (health ()) with
  | Ok fleet -> check fleet_t "the reading" expected fleet
  | Error error -> fail (Section.error_to_string error)
;;

let test_the_fields_the_stream_does_not_carry_are_ignored () =
  check bool "with and without them" true
    (match
       ( Section.fleet_of_health_fields (health ())
       , Section.fleet_of_health_fields
           [ "keeper_fleet_safety", `Assoc section_pairs ] )
     with
     | Ok a, Ok b -> F.equal_fleet a b
     | Ok _, Error _ | Error _, Ok _ | Error _, Error _ -> false)
;;

let test_every_field_is_required () =
  List.iter
    (fun (key, _) ->
       check bool (Printf.sprintf "without %s" key) true
         (is_unreadable
            (Section.fleet_of_health_fields (health ~pairs:(without key section_pairs) ()))))
    section_pairs
;;

let test_a_field_of_the_wrong_type_is_unreadable () =
  List.iter
    (fun (key, value) ->
       let wrong : Yojson.Safe.t =
         match value with
         | `String _ -> `Int 1
         | `Int _ | `Bool _ | `List _ | `Null | `Intlit _ | `Float _ | `Assoc _ -> `String "x"
       in
       check bool (Printf.sprintf "%s of the wrong type" key) true
         (is_unreadable
            (Section.fleet_of_health_fields
               (health ~pairs:(replacing key wrong section_pairs) ()))))
    section_pairs
;;

let test_a_negative_count_is_unreadable () =
  check bool "negative" true
    (is_unreadable
       (Section.fleet_of_health_fields
          (health ~pairs:(replacing "failing_keeper_fiber_count" (`Int (-1)) section_pairs) ())))
;;

let test_a_word_this_build_does_not_know_is_unreadable () =
  check bool "grade" true
    (is_unreadable
       (Section.fleet_of_health_fields
          (health ~pairs:(replacing "status" (`String "thriving") section_pairs) ())));
  check bool "blocker" true
    (is_unreadable
       (Section.fleet_of_health_fields
          (health ~pairs:(replacing "blocker" (`String "gremlins") section_pairs) ())))
;;

let test_no_blocker_is_a_reading () =
  match
    Section.fleet_of_health_fields
      (health ~pairs:(replacing "blocker" `Null section_pairs) ())
  with
  | Ok fleet -> check bool "none" true (Option.is_none fleet.F.fs_blocker)
  | Error error -> fail (Section.error_to_string error)
;;

let test_names_come_out_sorted_without_duplicates () =
  match
    Section.fleet_of_health_fields
      (health
         ~pairs:(replacing "running_keeper_names" (strings [ "b"; "a"; "b" ]) section_pairs)
         ())
  with
  | Ok fleet ->
    check (list string) "canonical" [ "a"; "b" ] (F.Names.to_list fleet.F.fs_running_names)
  | Error error -> fail (Section.error_to_string error)
;;

let test_the_placeholder_is_not_a_reading () =
  let placeholder ?(timed_out = false) status extra : (string * Yojson.Safe.t) list =
    [ "keeper_fleet_safety"
    , `Assoc ([ "status", `String status; "component_timed_out", `Bool timed_out ] @ extra)
    ]
  in
  check bool "warming" true
    (match Section.fleet_of_health_fields (placeholder "warming" []) with
     | Error (Section.Not_measured { status }) -> String.equal status "warming"
     | Error (Section.Scan_failed _ | Section.Unreadable _) | Ok _ -> false);
  check bool "section error is a failed scan" true
    (match
       Section.fleet_of_health_fields
         (placeholder "error" [ "error", `String "scan raised" ])
     with
     | Error (Section.Scan_failed F.Scan_failed) -> true
     | Error (Section.Not_measured _ | Section.Scan_failed _ | Section.Unreadable _) | Ok _ -> false);
  check bool "timeout flag is preserved" true
    (match Section.fleet_of_health_fields (placeholder ~timed_out:true "error" []) with
     | Error (Section.Scan_failed F.Scan_timed_out) -> true
     | Error (Section.Not_measured _ | Section.Scan_failed _ | Section.Unreadable _) | Ok _ -> false);
  check bool "timeout status is preserved" true
    (match Section.fleet_of_health_fields (placeholder "timeout" []) with
     | Error (Section.Scan_failed F.Scan_timed_out) -> true
     | Error (Section.Not_measured _ | Section.Scan_failed _ | Section.Unreadable _) | Ok _ -> false);
  check bool "unavailable is a failed scan" true
    (match Section.fleet_of_health_fields (placeholder "unavailable" []) with
     | Error (Section.Scan_failed F.Scan_failed) -> true
     | Error (Section.Not_measured _ | Section.Scan_failed _ | Section.Unreadable _) | Ok _ -> false);
  check bool "unknown placeholder status is unreadable" true
    (is_unreadable (Section.fleet_of_health_fields (placeholder "future" [])))
;;

let test_a_section_that_cannot_be_what_it_claims_is_unreadable () =
  check bool "no section" true (is_unreadable (Section.fleet_of_health_fields []));
  check bool "section is a list" true
    (is_unreadable (Section.fleet_of_health_fields [ "keeper_fleet_safety", `List [] ]));
  check bool "another schema" true
    (is_unreadable
       (Section.fleet_of_health_fields
          (health ~pairs:(replacing "schema" (`String "other.v9") section_pairs) ())));
  check bool "schema that is not a string" true
    (is_unreadable
       (Section.fleet_of_health_fields
          (health ~pairs:(replacing "schema" (`Int 1) section_pairs) ())));
  check bool "neither schema nor status" true
    (is_unreadable
       (Section.fleet_of_health_fields [ "keeper_fleet_safety", `Assoc [ "x", `Int 1 ] ]));
  check bool "placeholder status that is not a string" true
    (is_unreadable
       (Section.fleet_of_health_fields [ "keeper_fleet_safety", `Assoc [ "status", `Int 1 ] ]))
;;

let () =
  run "fleet_stream_health_section"
    [ ( "reading"
      , [ test_case "every key is read into its own field" `Quick
            test_every_key_is_read_into_its_own_field
        ; test_case "the fields the stream does not carry are ignored" `Quick
            test_the_fields_the_stream_does_not_carry_are_ignored
        ; test_case "no blocker is a reading" `Quick test_no_blocker_is_a_reading
        ; test_case "names come out sorted without duplicates" `Quick
            test_names_come_out_sorted_without_duplicates
        ; test_case "the placeholder is not a reading" `Quick
            test_the_placeholder_is_not_a_reading
        ] )
    ; ( "unreadable"
      , [ test_case "every field is required" `Quick test_every_field_is_required
        ; test_case "a field of the wrong type" `Quick
            test_a_field_of_the_wrong_type_is_unreadable
        ; test_case "a negative count" `Quick test_a_negative_count_is_unreadable
        ; test_case "a word this build does not know" `Quick
            test_a_word_this_build_does_not_know_is_unreadable
        ; test_case "a section that cannot be what it claims" `Quick
            test_a_section_that_cannot_be_what_it_claims_is_unreadable
        ] )
    ]
;;
