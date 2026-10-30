open Alcotest
module F = Masc.Fleet_stream
module Grade = Masc.Keeper_fleet_grade
module Blocker = Masc.Keeper_fleet_blocker

let revision n =
  match F.Revision.of_int n with
  | Some revision -> revision
  | None -> failf "revision %d" n
;;

let names words =
  match F.Names.of_canonical_list words with
  | Some names -> names
  | None -> failf "not canonical: %s" (String.concat "," words)
;;

(* Every field holds a value no other field holds. A decoder that read one key
   into another field would not give back an equal reading. *)
let sample_fleet : F.fleet =
  { F.fs_status = Grade.Fleet_degraded
  ; fs_blocker = Some Blocker.Reaction_capacity_below_target
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

let quiet_fleet : F.fleet =
  { sample_fleet with
    fs_status = Grade.Fleet_ok
  ; fs_blocker = None
  ; fs_operator_action_required = false
  ; fs_bootable_names = F.Names.empty
  }
;;

let snapshot =
  F.Snapshot
    { revision = revision 7
    ; measured_at = 1793162263.022031
    ; fleet = sample_fleet
    ; degraded = None
    }
;;

let degraded_snapshot =
  F.Snapshot
    { revision = revision 10
    ; measured_at = 1793162263.022031
    ; fleet = sample_fleet
    ; degraded = Some { F.since = 1793162300.5; reason = F.Scan_failed }
    }
;;

let changed =
  F.Changed { revision = revision 8; measured_at = 1793162300.5; fleet = quiet_fleet }
;;

let degraded =
  F.Degraded
    { revision = revision 9
    ; degradation = { F.since = 1793162400.0; reason = F.Scan_timed_out }
    }
;;

let unavailable =
  F.Unavailable_snapshot
    { revision = revision 1
    ; degradation = { F.since = 1793162400.0; reason = F.Scan_failed }
    }
;;

let error_t =
  testable
    (fun fmt error -> Format.pp_print_string fmt (F.decode_error_to_string error))
    ( = )
;;

let event_t =
  testable
    (fun fmt event ->
       Format.pp_print_string fmt (Yojson.Safe.to_string (F.encode event)))
    ( = )
;;

let decoded = result event_t error_t

(* Edits on one JSON object, so a rejection test changes exactly one thing. *)
let map_member name f (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields ->
    `Assoc (List.map (fun (key, value) -> if String.equal key name then key, f value else key, value) fields)
  | other -> other
;;

let drop_member name (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (List.filter (fun (key, _) -> not (String.equal key name)) fields)
  | other -> other
;;

let add_member name value (json : Yojson.Safe.t) : Yojson.Safe.t =
  match json with
  | `Assoc fields -> `Assoc (fields @ [ name, value ])
  | other -> other
;;

let in_fleet edit json = map_member "fleet" edit json
let reject label json expected = check decoded label (Error expected) (F.decode json)

let test_every_event_survives_the_wire () =
  List.iter
    (fun event ->
       check decoded "decode (encode e)" (Ok event) (F.decode (F.encode event));
       let through_text =
         Yojson.Safe.from_string (Yojson.Safe.to_string (F.encode event))
       in
       check decoded "through JSON text" (Ok event) (F.decode through_text))
    [ unavailable
    ; snapshot
    ; degraded_snapshot
    ; changed
    ; degraded
    ; F.Snapshot { revision = revision 1; measured_at = 0.0; fleet = quiet_fleet; degraded = None }
    ]
;;

let test_a_decoded_event_encodes_to_the_same_json () =
  List.iter
    (fun event ->
       match F.decode (F.encode event) with
       | Error error -> fail (F.decode_error_to_string error)
       | Ok again ->
         check bool "same JSON" true
           (Yojson.Safe.equal (F.encode event) (F.encode again)))
    [ unavailable; snapshot; degraded_snapshot; changed; degraded ]
;;

(* The wire names are the contract with anything that is not this build. A
   rename that touched encode and decode together would pass the round trip, so
   the names are fixed here. *)
let test_the_wire_names_are_fixed () =
  check string "unavailable snapshot"
    {|{"event":"unavailable_snapshot","schema":1,"revision":1,"since":1793162400.0,"reason":"scan_failed"}|}
    (Yojson.Safe.to_string (F.encode unavailable));
  check string "degraded"
    {|{"event":"degraded","revision":9,"since":1793162400.0,"reason":"scan_timed_out"}|}
    (Yojson.Safe.to_string (F.encode degraded));
  (match F.encode degraded_snapshot with
   | `Assoc top ->
     (match List.assoc_opt "degraded" top with
      | Some (`Assoc nested) ->
        check (list string) "degraded keys" [ "reason"; "since" ]
          (List.sort String.compare (List.map fst nested))
      | _ -> fail "no degraded object")
   | _ -> fail "not an object");
  (match F.encode snapshot with
   | `Assoc top ->
     check (list string) "snapshot keys"
       [ "degraded"; "event"; "fleet"; "measured_at"; "revision"; "schema" ]
       (List.sort String.compare (List.map fst top))
   | _ -> fail "not an object");
  match F.encode snapshot with
  | `Assoc top ->
    (match List.assoc_opt "fleet" top with
     | Some (`Assoc fleet) ->
       check (list string) "fleet keys"
         [ "active_task_owner_scan_error_count"
         ; "active_task_owner_without_fiber_count"
         ; "blocker"
         ; "bootable_count"
         ; "bootable_names"
         ; "completion_authority_pending_count"
         ; "executable_count"
         ; "executable_names"
         ; "failing_count"
         ; "official_client_recovery_required_count"
         ; "official_client_recovery_required_names"
         ; "operator_action_required"
         ; "paused_count"
         ; "reaction_capacity_shortfall"
         ; "recovering_count"
         ; "running_count"
         ; "running_names"
         ; "status"
         ; "target_reaction_capacity"
         ; "turn_configuration_error_count"
         ; "turn_configuration_error_names"
         ]
         (List.sort String.compare (List.map fst fleet))
     | _ -> fail "no fleet object")
  | _ -> fail "not an object"
;;

let test_a_missing_field_is_named () =
  let json = F.encode snapshot in
  reject "no revision" (drop_member "revision" json)
    (F.Missing_field { at = "event"; field = "revision" });
  reject "no fleet" (drop_member "fleet" json)
    (F.Missing_field { at = "event"; field = "fleet" });
  reject "no running_count"
    (in_fleet (drop_member "running_count") json)
    (F.Missing_field { at = "fleet"; field = "running_count" });
  reject "no blocker key at all"
    (in_fleet (drop_member "blocker") json)
    (F.Missing_field { at = "fleet"; field = "blocker" });
  reject "no event name" (drop_member "event" json)
    (F.Missing_field { at = "event"; field = "event" })
;;

let test_a_field_this_build_does_not_know_is_refused () =
  let json = F.encode snapshot in
  reject "extra on the event" (add_member "extra" (`Int 1) json)
    (F.Unknown_field { at = "event"; field = "extra" });
  reject "extra in the fleet"
    (in_fleet (add_member "extra" (`Int 1)) json)
    (F.Unknown_field { at = "fleet"; field = "extra" });
  reject "schema on a Changed"
    (add_member "schema" (`Int F.schema_version) (F.encode changed))
    (F.Unknown_field { at = "event"; field = "schema" });
  reject "measured_at on a Degraded"
    (add_member "measured_at" (`Float 1.0) (F.encode degraded))
    (F.Unknown_field { at = "event"; field = "measured_at" })
;;

let test_a_degraded_state_is_read_as_exactly_as_the_rest () =
  let json = F.encode degraded_snapshot in
  reject "no degraded key" (drop_member "degraded" (F.encode snapshot))
    (F.Missing_field { at = "event"; field = "degraded" });
  reject "extra field in degraded"
    (map_member "degraded" (add_member "extra" (`Int 1)) json)
    (F.Unknown_field { at = "degraded"; field = "extra" });
  reject "no since in degraded"
    (map_member "degraded" (drop_member "since") json)
    (F.Missing_field { at = "degraded"; field = "since" });
  reject "negative since in degraded"
    (map_member "degraded" (map_member "since" (fun _ -> `Float (-1.0))) json)
    (F.Out_of_range { at = "degraded"; field = "since" });
  reject "unknown reason in degraded"
    (map_member "degraded" (map_member "reason" (fun _ -> `String "bored")) json)
    (F.Unknown_word { at = "degraded"; field = "reason"; word = "bored" });
  reject "degraded as a string"
    (map_member "degraded" (fun _ -> `String "yes") json)
    (F.Wrong_type { at = "event"; field = "degraded"; expected = "an object or null" });
  reject "no since on a Degraded event"
    (drop_member "since" (F.encode degraded))
    (F.Missing_field { at = "event"; field = "since" })
;;

let test_a_field_named_twice_is_refused () =
  reject "revision twice"
    (add_member "revision" (`Int 99) (F.encode changed))
    (F.Duplicate_field { at = "event"; field = "revision" })
;;

let test_a_value_of_the_wrong_type_is_refused () =
  let json = F.encode snapshot in
  reject "count as string"
    (in_fleet (map_member "bootable_count" (fun _ -> `String "3")) json)
    (F.Wrong_type { at = "fleet"; field = "bootable_count"; expected = "an integer" });
  reject "count as float"
    (in_fleet (map_member "bootable_count" (fun _ -> `Float 3.0)) json)
    (F.Wrong_type { at = "fleet"; field = "bootable_count"; expected = "an integer" });
  reject "flag as int"
    (in_fleet (map_member "operator_action_required" (fun _ -> `Int 1)) json)
    (F.Wrong_type { at = "fleet"; field = "operator_action_required"; expected = "a boolean" });
  reject "fleet as list"
    (map_member "fleet" (fun _ -> `List []) json)
    (F.Not_an_object { at = "fleet" });
  reject "names with a non-string"
    (in_fleet (map_member "running_names" (fun _ -> `List [ `Int 1 ])) json)
    (F.Wrong_type { at = "fleet"; field = "running_names"; expected = "a list of strings" });
  reject "names as string"
    (in_fleet (map_member "running_names" (fun _ -> `String "alpha")) json)
    (F.Wrong_type { at = "fleet"; field = "running_names"; expected = "a list of strings" });
  reject "time as string"
    (map_member "measured_at" (fun _ -> `String "now") json)
    (F.Wrong_type { at = "event"; field = "measured_at"; expected = "a number of seconds" });
  reject "event name as int"
    (map_member "event" (fun _ -> `Int 1) json)
    (F.Wrong_type { at = "event"; field = "event"; expected = "a string" });
  reject "not an object" (`List []) (F.Not_an_object { at = "event" })
;;

let test_a_number_out_of_range_is_refused () =
  let json = F.encode snapshot in
  reject "negative count"
    (in_fleet (map_member "failing_count" (fun _ -> `Int (-1))) json)
    (F.Out_of_range { at = "fleet"; field = "failing_count" });
  reject "revision 0" (map_member "revision" (fun _ -> `Int 0) json)
    (F.Out_of_range { at = "event"; field = "revision" });
  List.iter
    (fun (label, seconds) ->
       reject label
         (map_member "measured_at" (fun _ -> `Float seconds) json)
         (F.Out_of_range { at = "event"; field = "measured_at" }))
    [ "nan", Float.nan; "infinity", Float.infinity; "negative", -1.0 ];
  check decoded "a whole number of seconds reads as time"
    (Ok
       (F.Snapshot
          { revision = revision 7; measured_at = 5.0; fleet = sample_fleet; degraded = None }))
    (F.decode (map_member "measured_at" (fun _ -> `Int 5) json))
;;

let test_a_word_that_names_no_variant_is_refused () =
  let json = F.encode snapshot in
  reject "grade"
    (in_fleet (map_member "status" (fun _ -> `String "fleet_thriving")) json)
    (F.Unknown_word { at = "fleet"; field = "status"; word = "fleet_thriving" });
  reject "blocker"
    (in_fleet (map_member "blocker" (fun _ -> `String "gremlins")) json)
    (F.Unknown_word { at = "fleet"; field = "blocker"; word = "gremlins" });
  reject "blocker of the wrong type"
    (in_fleet (map_member "blocker" (fun _ -> `Int 1)) json)
    (F.Wrong_type { at = "fleet"; field = "blocker"; expected = "a string or null" });
  reject "degraded reason"
    (map_member "reason" (fun _ -> `String "bored") (F.encode degraded))
    (F.Unknown_word { at = "event"; field = "reason"; word = "bored" });
  reject "event" (map_member "event" (fun _ -> `String "hello") json)
    (F.Unknown_event "hello")
;;

let test_every_grade_and_blocker_survives_the_wire () =
  List.iter
    (fun grade ->
       let event =
         F.Changed
           { revision = revision 2
           ; measured_at = 1.0
           ; fleet = { sample_fleet with fs_status = grade }
           }
       in
       check decoded (Grade.wire_name grade) (Ok event) (F.decode (F.encode event)))
    Grade.all;
  List.iter
    (fun blocker ->
       let event =
         F.Changed
           { revision = revision 2
           ; measured_at = 1.0
           ; fleet = { sample_fleet with fs_blocker = Some blocker }
           }
       in
       check decoded (Blocker.wire_name blocker) (Ok event) (F.decode (F.encode event)))
    Blocker.all
;;

let test_a_name_list_must_already_be_sorted_without_duplicates () =
  let json = F.encode snapshot in
  let with_names words =
    in_fleet
      (map_member "bootable_names" (fun _ -> `List (List.map (fun w -> `String w) words)))
      json
  in
  reject "unsorted" (with_names [ "beta"; "alpha" ])
    (F.Not_canonical { at = "fleet"; field = "bootable_names" });
  reject "duplicate" (with_names [ "alpha"; "alpha" ])
    (F.Not_canonical { at = "fleet"; field = "bootable_names" });
  check bool "empty list is canonical" true
    (match F.decode (with_names []) with Ok _ -> true | Error _ -> false)
;;

let test_names_are_canonical_by_construction () =
  check (list string) "of_list sorts and drops duplicates" [ "a"; "b"; "c" ]
    (F.Names.to_list (F.Names.of_list [ "c"; "a"; "b"; "a" ]));
  check bool "equal whatever the input order" true
    (F.Names.equal (F.Names.of_list [ "b"; "a" ]) (F.Names.of_list [ "a"; "b"; "a" ]));
  check bool "different sets are not equal" false
    (F.Names.equal (F.Names.of_list [ "a" ]) (F.Names.of_list [ "b" ]));
  check bool "a subset is not equal" false
    (F.Names.equal (F.Names.of_list [ "a" ]) (F.Names.of_list [ "a"; "b" ]));
  check (option (list string)) "canonical input" (Some [ "a"; "b" ])
    (Option.map F.Names.to_list (F.Names.of_canonical_list [ "a"; "b" ]));
  check (option (list string)) "unsorted input" None
    (Option.map F.Names.to_list (F.Names.of_canonical_list [ "b"; "a" ]));
  check int "length" 2 (F.Names.length (F.Names.of_list [ "x"; "y"; "x" ]));
  check bool "mem" true (F.Names.mem "y" (F.Names.of_list [ "x"; "y" ]));
  check bool "not mem" false (F.Names.mem "z" (F.Names.of_list [ "x"; "y" ]))
;;

let test_the_schema_is_checked_before_anything_else () =
  let json = F.encode snapshot in
  reject "unavailable snapshot requires a matching schema"
    (map_member "schema" (fun _ -> `Int 99) (F.encode unavailable))
    (F.Schema_mismatch { expected = F.schema_version; received = 99 });
  reject "another schema"
    (map_member "schema" (fun _ -> `Int (F.schema_version + 1)) json)
    (F.Schema_mismatch { expected = F.schema_version; received = F.schema_version + 1 });
  (* A newer server may have changed every field after [schema], so the answer
     is the mismatch, not whichever field this build trips over first. *)
  reject "another schema and no fleet"
    (drop_member "fleet" (map_member "schema" (fun _ -> `Int 99) json))
    (F.Schema_mismatch { expected = F.schema_version; received = 99 });
  reject "no schema" (drop_member "schema" json)
    (F.Missing_field { at = "event"; field = "schema" });
  reject "schema as string"
    (map_member "schema" (fun _ -> `String "1") json)
    (F.Wrong_type { at = "event"; field = "schema"; expected = "an integer" })
;;

let test_fleets_compare_by_content () =
  check bool "same" true (F.equal_fleet sample_fleet sample_fleet);
  check bool "another grade" false
    (F.equal_fleet sample_fleet { sample_fleet with fs_status = Grade.Fleet_blocked });
  check bool "another count" false
    (F.equal_fleet sample_fleet { sample_fleet with fs_paused_count = 99 });
  check bool "another name set" false
    (F.equal_fleet sample_fleet
       { sample_fleet with fs_running_names = names [ "alpha" ] });
  check bool "blocker present or not" false
    (F.equal_fleet sample_fleet { sample_fleet with fs_blocker = None });
  check bool "the same set listed in any order" true
    (F.equal_fleet sample_fleet
       { sample_fleet with
         fs_bootable_names = F.Names.of_list [ "gamma"; "alpha"; "beta" ]
       })
;;

let test_revisions_say_whether_one_follows_another () =
  let r = revision 5 in
  check bool "next follows" true (F.Revision.is_next ~after:r (F.Revision.next r));
  check bool "same does not follow" false (F.Revision.is_next ~after:r r);
  check bool "a gap does not follow" false
    (F.Revision.is_next ~after:r (F.Revision.next (F.Revision.next r)));
  check bool "backwards does not follow" false (F.Revision.is_next ~after:r (revision 4));
  check (option int) "below 1" None (Option.map F.Revision.to_int (F.Revision.of_int 0));
  check int "first" 1 (F.Revision.to_int F.Revision.first);
  check bool "event revision" true
    (F.Revision.equal (F.revision_of_event snapshot) (revision 7)
     && F.Revision.equal (F.revision_of_event changed) (revision 8)
     && F.Revision.equal (F.revision_of_event degraded) (revision 9))
;;

let () =
  run "fleet_stream"
    [ ( "wire"
      , [ test_case "every event survives the wire" `Quick test_every_event_survives_the_wire
        ; test_case "a decoded event encodes to the same JSON" `Quick
            test_a_decoded_event_encodes_to_the_same_json
        ; test_case "the wire names are fixed" `Quick test_the_wire_names_are_fixed
        ; test_case "every grade and blocker survives the wire" `Quick
            test_every_grade_and_blocker_survives_the_wire
        ] )
    ; ( "rejects"
      , [ test_case "a missing field is named" `Quick test_a_missing_field_is_named
        ; test_case "a field this build does not know" `Quick
            test_a_field_this_build_does_not_know_is_refused
        ; test_case "a degraded state is read exactly" `Quick
            test_a_degraded_state_is_read_as_exactly_as_the_rest
        ; test_case "a field named twice" `Quick test_a_field_named_twice_is_refused
        ; test_case "a value of the wrong type" `Quick test_a_value_of_the_wrong_type_is_refused
        ; test_case "a number out of range" `Quick test_a_number_out_of_range_is_refused
        ; test_case "a word that names no variant" `Quick
            test_a_word_that_names_no_variant_is_refused
        ; test_case "a name list must be canonical" `Quick
            test_a_name_list_must_already_be_sorted_without_duplicates
        ; test_case "the schema is checked first" `Quick
            test_the_schema_is_checked_before_anything_else
        ] )
    ; ( "values"
      , [ test_case "names are canonical by construction" `Quick
            test_names_are_canonical_by_construction
        ; test_case "fleets compare by content" `Quick test_fleets_compare_by_content
        ; test_case "revisions say whether one follows another" `Quick
            test_revisions_say_whether_one_follows_another
        ] )
    ]
;;
