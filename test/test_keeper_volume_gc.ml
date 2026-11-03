(* Reclamation of retired keepers' Apple volumes. The feature is the
   decision: which volumes a report judges reclaimable and which evidence
   keeps the rest, and that deletion happens only on request and only for
   the candidates. Everything runs against a scripted runtime through the
   injected [run], the way the volume-removal cases in
   test_keeper_sandbox_microvm.ml drive theirs. *)

module Gc = Masc.Keeper_volume_gc

let ok_exn = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "expected Ok, got Error %S" detail
;;

let adjacent ~flag ~value argv =
  let rec go = function
    | a :: b :: rest -> (String.equal a flag && String.equal b value) || go (b :: rest)
    | _ -> false
  in
  go argv
;;

(* The volume a claims-read helper was mounted on: the value of the
   [--volume NAME:/masc-claims] argument, back to the bare name. *)
let mounted_volume argv =
  let rec go = function
    | flag :: value :: _rest when String.equal flag "--volume" ->
      let suffix = ":" ^ Masc.Keeper_sandbox_microvm.claims_guest_root in
      let length = String.length value - String.length suffix in
      if length > 0 && String.ends_with ~suffix value
      then Some (String.sub value 0 length)
      else None
    | _ :: rest -> go rest
    | [] -> None
  in
  go argv
;;

let deleted_volume_names sent =
  List.filter_map
    (fun argv ->
       if adjacent ~flag:"volume" ~value:"delete" argv
       then (
         match List.rev argv with
         | name :: _ -> Some name
         | [] -> None)
       else None)
    sent
;;

let test_volume_names_parse_back_to_their_keeper () =
  let expect_masc name ~role ~keeper_name =
    match Gc.masc_keeper_volume_of_name name with
    | Gc.Masc_keeper_volume { role = actual_role; volume_name; keeper_name = actual } ->
      Alcotest.(check string) "the volume name round-trips" name volume_name;
      Alcotest.(check string) "the keeper name is the remainder" keeper_name actual;
      Alcotest.(check bool) "the role matches"
        true
        (match role, actual_role with
         | Gc.Work_role, Gc.Work_role | Gc.Build_role, Gc.Build_role -> true
         | _ -> false)
    | Gc.Foreign_volume _ ->
      Alcotest.failf "%s is a keeper volume this product builds" name
  in
  expect_masc "masc-keeper-work-polisher" ~role:Gc.Work_role ~keeper_name:"polisher";
  expect_masc "masc-keeper-build-edgar.a.poe" ~role:Gc.Build_role ~keeper_name:"edgar.a.poe";
  List.iter
    (fun name ->
       match Gc.masc_keeper_volume_of_name name with
       | Gc.Foreign_volume foreign ->
         Alcotest.(check string) "not ours" name foreign
       | Gc.Masc_keeper_volume _ ->
         Alcotest.failf "%s is not a keeper volume this product builds" name)
    [ "unrelated-volume"
    ; "masc-keeper-work-" (* no keeper name after the prefix *)
    ; "masc-keeper-work-has/slash" (* not a valid volume segment *)
    ; "masc-keeper-work-../escape" ]
;;

(* The CLI lists volume objects, not the names-only fixture inputs below. *)
let volume_listing names =
  Yojson.Safe.to_string
    (`List
      (List.map
         (fun name ->
            `Assoc
              [ "id", `String name
              ; "configuration", `Assoc [ "name", `String name; "format", `String "ext4" ]
              ])
         names))
;;

(* A scripted runtime for the reclamation. The volume listing is live: a
   [volume delete] that answers 0 removes its name from what later listings
   show, so a candidate's removal settles the way the real runtime settles
   it. [containers] answers every [list --all] (one per keeper judged),
   [claims] answers a claims read by the volume it mounted, and [delete_answers]
   name volumes whose delete must fail (the name stays listed). Calls are
   recorded. *)
let scripted_gc ~volumes ~containers ~claims ~delete_answers () =
  let sent = ref [] in
  let initial =
    match Yojson.Safe.from_string volumes with
    | `List entries ->
      List.map
        (function
          | `String name -> name
          | _ -> Alcotest.fail "the fixture's volume names must be strings")
        entries
    | _ -> Alcotest.fail "the fixture's volume listing must be a JSON array"
  in
  let remaining = ref initial in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if List.exists (String.equal "--all") argv
    then Unix.WEXITED 0, containers, ""
    else if adjacent ~flag:"volume" ~value:"list" argv
    then
      Unix.WEXITED 0,
      volume_listing !remaining,
      ""
    else if List.exists (String.equal "run") argv
    then (
      match mounted_volume argv with
      | Some volume_name -> claims volume_name
      | None -> Unix.WEXITED 0, "", "")
    else if adjacent ~flag:"volume" ~value:"delete" argv
    then (
      let name = List.nth argv (List.length argv - 1) in
      if List.mem name delete_answers
      then Unix.WEXITED 1, "", "volume in use"
      else (
        remaining := List.filter (fun n -> not (String.equal n name)) !remaining;
        Unix.WEXITED 0, "", ""))
    else Alcotest.failf "unexpected command: %s" (String.concat " " argv)
  in
  let call ?(registered = fun _ -> false) ?(claims_image = Some "masc-test-minimal:image") ~execute () =
    let report =
      ok_exn
        (Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
           ~registered_keeper:registered
           ~claims_image
           ~execute)
    in
    report, List.rev !sent
  in
  call
;;

(* Four scoping labels, the way a booted guest is labeled; the inventory
   decoder projects anything less to [None] and the row stops being an
   owner. *)
let guest_listing name =
  String.concat ""
    [ {|[{"id":"masc-keeper-vm-|} ; name ; {|-net-none-abcd1234",|}
    ; {|"configuration":{"labels":{|}
    ; {|"masc.mcp.component":"keeper-sandbox",|}
    ; {|"masc.mcp.base_path_hash":"abcd1234",|}
    ; {|"masc.mcp.kind":"persistent",|}
    ; {|"masc.mcp.keeper":"|} ; name ; {|"}}}|}
    ; "]"
    ]
;;

let test_the_decision_table_keeps_every_protected_volume () =
  let volumes =
    Yojson.Safe.to_string
      (`List
         [ `String "masc-keeper-work-retired"
         ; `String "masc-keeper-build-retired"
         ; `String "masc-keeper-work-shared"
         ; `String "masc-keeper-work-registered"
         ; `String "masc-keeper-work-legacy"
         ; `String "masc-keeper-work-live"
         ; `String "masc-keeper-build-orphan"
         ; `String "unrelated-volume"
         ])
  in
  let claims volume_name =
    if String.equal volume_name "masc-keeper-work-shared"
    then Unix.WEXITED 0, {|["/ws/other"]|}, ""
    else if String.equal volume_name "masc-keeper-work-retired" then Unix.WEXITED 0, "[]\n", ""
    else if String.equal volume_name "masc-keeper-work-legacy" then Unix.WEXITED 0, "", ""
    else if String.equal volume_name "masc-keeper-work-live" then
      Alcotest.fail "a live guest is kept before any claims read runs"
    else Unix.WEXITED 0, "[]\n", ""
  in
  let call =
    scripted_gc ~volumes ~containers:(guest_listing "live") ~claims ~delete_answers:[] ()
  in
  let report, sent = call ~registered:(fun name -> String.equal name "registered") ~execute:true () in
  Alcotest.(check (list string)) "a foreign volume is named, not judged"
    [ "unrelated-volume" ] report.Gc.foreign_volumes;
  let outcome_of keeper_name =
    match
      List.find_opt
        (fun (verdict : Gc.keeper_verdict) -> String.equal verdict.Gc.keeper_name keeper_name)
        report.Gc.keepers
    with
    | Some { Gc.outcome; _ } -> outcome
    | None -> Alcotest.failf "keeper %s was not judged" keeper_name
  in
  (match outcome_of "live" with
   | Gc.Kept (Gc.Referenced_by_containers _) -> ()
   | other -> Alcotest.failf "a live guest keeps the volumes: %s" (Gc.keeper_outcome_to_string other));
  (match outcome_of "shared" with
   | Gc.Kept (Gc.Claimed_by_workspaces [ "/ws/other" ]) -> ()
   | other -> Alcotest.failf "a claimed volume stays: %s" (Gc.keeper_outcome_to_string other));
  (match outcome_of "registered" with
   | Gc.Kept Gc.Registered_in_this_workspace -> ()
   | other -> Alcotest.failf "a registered keeper stays: %s" (Gc.keeper_outcome_to_string other));
  (match outcome_of "legacy" with
   | Gc.Kept (Gc.Unverified detail) ->
     Alcotest.(check bool) "the missing marker is named" true
       (Astring.String.is_infix ~affix:"claims marker absent" detail)
   | other ->
     Alcotest.failf "a legacy volume without a marker stays: %s" (Gc.keeper_outcome_to_string other));
  (match outcome_of "retired" with
   | Gc.Kept (Gc.Unverified detail) ->
     Alcotest.(check bool) "the empty marker is named" true
       (Astring.String.is_infix ~affix:"claims marker empty" detail)
   | other ->
     Alcotest.failf "an empty marker cannot exclude an unrecorded owner: %s"
       (Gc.keeper_outcome_to_string other));
  (match outcome_of "orphan" with
   | Gc.Reclaimed -> ()
   | other ->
     Alcotest.failf "an unprotected build-only volume is reclaimable: %s"
       (Gc.keeper_outcome_to_string other));
  Alcotest.(check (list string))
    "only the listed build volume is deleted, never an absent work volume"
    [ "masc-keeper-build-orphan" ]
    (deleted_volume_names sent)
;;

let test_a_report_without_execute_touches_nothing () =
  let volumes = {|["masc-keeper-build-retired"]|} in
  let call =
    scripted_gc ~volumes ~containers:"[]"
      ~claims:(fun _ -> Unix.WEXITED 0, "[]\n", "")
      ~delete_answers:[] ()
  in
  let report, sent = call ~execute:false () in
  (match report.Gc.keepers with
   | [ { Gc.keeper_name = "retired"; Gc.outcome = Gc.Reclaim_candidate; _ } ] -> ()
   | keepers ->
     Alcotest.failf "one candidate reported, got %d keepers" (List.length keepers));
  Alcotest.(check (list string)) "a report deletes nothing" [] (deleted_volume_names sent)
;;

let test_a_failed_deletion_is_reported () =
  let volumes = {|["masc-keeper-build-broken"]|} in
  (* The build volume's delete fails and its name stays in the settling
     listing, which is the removal's own unconfirmed path. *)
  let call =
    scripted_gc ~volumes ~containers:"[]"
      ~claims:(fun _ -> Unix.WEXITED 0, "", "")
      ~delete_answers:[ "masc-keeper-build-broken" ] ()
  in
  let report, _sent = call ~execute:true () in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Reclaim_failed detail; _ } ] ->
     Alcotest.(check bool) "the failed removal is named" true
       (Astring.String.is_infix ~affix:"masc-keeper-build-broken" detail)
   | keepers ->
     Alcotest.failf "expected one reclaim failure, got %d keepers" (List.length keepers))
;;

let test_build_only_cleanup_preserves_a_keeper_whose_work_volume_appeared () =
  let sent = ref [] in
  let listings = ref 0 in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if List.exists (String.equal "--all") argv
    then Unix.WEXITED 0, "[]", ""
    else if adjacent ~flag:"volume" ~value:"list" argv
    then (
      incr listings;
      if !listings = 1
      then Unix.WEXITED 0, volume_listing [ "masc-keeper-build-racing" ], ""
      else
        (* A peer boots after the verdict: its work volume is already there
           when the delete-time confirmation runs. *)
        Unix.WEXITED 0, volume_listing [ "masc-keeper-build-racing"; "masc-keeper-work-racing" ], "")
    else if adjacent ~flag:"volume" ~value:"delete" argv
    then Alcotest.fail "no delete may run once the shape has changed"
    else Alcotest.failf "unexpected command: %s" (String.concat " " argv)
  in
  let report =
    ok_exn
      (Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
         ~registered_keeper:(fun _ -> false)
         ~claims_image:(Some "masc-test-minimal:image")
         ~execute:true)
  in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Kept (Gc.Unverified detail); _ } ] ->
     Alcotest.(check bool) "the appearing work volume is named" true
       (Astring.String.is_infix ~affix:"masc-keeper-work-racing" detail)
   | keepers -> Alcotest.failf "expected one preserved keeper, got %d" (List.length keepers));
  Alcotest.(check (list string)) "nothing was deleted" [] (deleted_volume_names (List.rev !sent));
  Alcotest.(check int) "verdict and confirmation listings were read" 2 !listings
;;

let test_build_only_cleanup_preserves_a_keeper_whose_build_volume_vanished () =
  let sent = ref [] in
  let listings = ref 0 in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if List.exists (String.equal "--all") argv
    then Unix.WEXITED 0, "[]", ""
    else if adjacent ~flag:"volume" ~value:"list" argv
    then (
      incr listings;
      if !listings = 1
      then Unix.WEXITED 0, volume_listing [ "masc-keeper-build-gone" ], ""
      else Unix.WEXITED 0, volume_listing [], "")
    else if adjacent ~flag:"volume" ~value:"delete" argv
    then Alcotest.fail "no delete may run for a keeper the confirmation cannot see"
    else Alcotest.failf "unexpected command: %s" (String.concat " " argv)
  in
  let report =
    ok_exn
      (Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
         ~registered_keeper:(fun _ -> false)
         ~claims_image:(Some "masc-test-minimal:image")
         ~execute:true)
  in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Kept (Gc.Unverified detail); _ } ] ->
     Alcotest.(check bool) "the absence is named" true
       (Astring.String.is_infix ~affix:"absent from the delete-time listing" detail)
   | keepers -> Alcotest.failf "expected one preserved keeper, got %d" (List.length keepers));
  Alcotest.(check (list string)) "nothing was deleted" [] (deleted_volume_names (List.rev !sent))
;;

let test_build_only_cleanup_preserves_a_keeper_whose_confirmation_fails () =
  let sent = ref [] in
  let listings = ref 0 in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if List.exists (String.equal "--all") argv
    then Unix.WEXITED 0, "[]", ""
    else if adjacent ~flag:"volume" ~value:"list" argv
    then (
      incr listings;
      if !listings = 1
      then Unix.WEXITED 0, volume_listing [ "masc-keeper-build-unconfirmed" ], ""
      else Unix.WEXITED 1, "", "container system is not running")
    else if adjacent ~flag:"volume" ~value:"delete" argv
    then Alcotest.fail "no delete may run without a confirmation"
    else Alcotest.failf "unexpected command: %s" (String.concat " " argv)
  in
  let report =
    ok_exn
      (Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
         ~registered_keeper:(fun _ -> false)
         ~claims_image:(Some "masc-test-minimal:image")
         ~execute:true)
  in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Kept (Gc.Unverified detail); _ } ] ->
     Alcotest.(check bool) "the failed confirmation is named" true
       (Astring.String.is_infix ~affix:"cannot confirm volume" detail)
   | keepers -> Alcotest.failf "expected one preserved keeper, got %d" (List.length keepers));
  Alcotest.(check (list string)) "nothing was deleted" [] (deleted_volume_names (List.rev !sent))
;;

let test_without_an_image_there_is_no_claim_evidence () =
  let volumes = volume_listing [ "masc-keeper-work-retired" ] in
  let sent = ref [] in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if List.exists (String.equal "--all") argv
    then Unix.WEXITED 0, "[]", ""
    else if adjacent ~flag:"volume" ~value:"list" argv
    then Unix.WEXITED 0, volumes, ""
    else Alcotest.failf "unexpected command without an image: %s" (String.concat " " argv)
  in
  let report =
    ok_exn
      (Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
         ~registered_keeper:(fun _ -> false)
         ~claims_image:None
         ~execute:true)
  in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Kept (Gc.Unverified detail); _ } ] ->
     Alcotest.(check bool) "the missing image is named" true
       (Astring.String.is_infix ~affix:"no image" detail)
   | keepers ->
     Alcotest.failf
       "an unowned keeper without claim evidence stays kept, got %d keepers"
       (List.length keepers));
  Alcotest.(check bool) "no claims helper ran without an image" true
    (not (List.exists (fun argv -> List.exists (String.equal "run") argv) !sent));
  Alcotest.(check bool) "nothing was deleted" true
    (not (List.exists (fun argv -> adjacent ~flag:"volume" ~value:"delete" argv) !sent))
;;

let test_an_unreadable_claims_marker_keeps_the_volumes () =
  let volumes = {|["masc-keeper-work-corrupt"]|} in
  let call =
    scripted_gc ~volumes ~containers:"[]"
      ~claims:(fun _ -> Unix.WEXITED 0, "not json", "")
      ~delete_answers:[] ()
  in
  let report, sent = call ~execute:true () in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Kept (Gc.Unverified detail); _ } ] ->
     Alcotest.(check bool) "the unreadable marker is named" true
       (Astring.String.is_infix ~affix:"claims marker unreadable" detail)
   | keepers ->
     Alcotest.failf "an unreadable marker keeps the volumes, got %d keepers" (List.length keepers));
  Alcotest.(check (list string)) "nothing was deleted" [] (deleted_volume_names sent)
;;

let test_a_failed_volume_listing_is_an_error_and_nothing_runs () =
  let sent = ref [] in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if adjacent ~flag:"volume" ~value:"list" argv
    then Unix.WEXITED 1, "", "container system is not running"
    else Alcotest.failf "nothing else may run: %s" (String.concat " " argv)
  in
  (match
     Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
       ~registered_keeper:(fun _ -> false)
       ~claims_image:(Some "masc-test-minimal:image")
       ~execute:true
   with
   | Error detail ->
     Alcotest.(check bool) "the failed listing is named" true
       (Astring.String.is_infix ~affix:"volume listing failed" detail)
   | Ok _ -> Alcotest.fail "an unreadable listing produced a report");
  Alcotest.(check int) "only the listing was attempted" 1 (List.length !sent)
;;

let test_a_malformed_initial_listing_never_starts_reclamation () =
  let sent = ref [] in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if adjacent ~flag:"volume" ~value:"list" argv
    then Unix.WEXITED 0, {|[{"id":"masc-keeper-build-retired"},{"configuration":{}}]|}, ""
    else Alcotest.failf "nothing else may run: %s" (String.concat " " argv)
  in
  let result =
    Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
      ~registered_keeper:(fun _ -> false)
      ~claims_image:(Some "masc-test-minimal:image")
      ~execute:true
  in
  Alcotest.(check bool) "a partial inventory is refused" true (Result.is_error result);
  Alcotest.(check int) "only the listing was attempted" 1 (List.length !sent);
  Alcotest.(check (list string)) "no volume deletion was attempted" []
    (deleted_volume_names !sent)
;;

let test_a_malformed_settling_listing_does_not_prove_reclamation () =
  let sent = ref [] in
  let listings = ref 0 in
  let run ~timeout_sec:_ argv =
    sent := argv :: !sent;
    if List.exists (String.equal "--all") argv
    then Unix.WEXITED 0, "[]", ""
    else if adjacent ~flag:"volume" ~value:"list" argv
    then (
      incr listings;
      if !listings <= 2
      then Unix.WEXITED 0, volume_listing [ "masc-keeper-build-retired" ], ""
      else Unix.WEXITED 0, {|[{"id":42}]|}, "")
    else if adjacent ~flag:"volume" ~value:"delete" argv
    then Unix.WEXITED 0, "", ""
    else Alcotest.failf "unexpected command: %s" (String.concat " " argv)
  in
  let report =
    ok_exn
      (Gc.apple_keeper_volume_gc ~run ~timeout_sec:1.0
         ~registered_keeper:(fun _ -> false)
         ~claims_image:(Some "masc-test-minimal:image")
         ~execute:true)
  in
  (match report.Gc.keepers with
   | [ { Gc.outcome = Gc.Reclaim_failed _; _ } ] -> ()
   | keepers ->
     Alcotest.failf "expected unconfirmed reclamation, got %d keepers" (List.length keepers));
  Alcotest.(check (list string)) "only the listed build volume was attempted"
    [ "masc-keeper-build-retired" ] (deleted_volume_names (List.rev !sent));
  Alcotest.(check int) "verdict, confirmation, and settling inventories were read" 3 !listings
;;

let () =
  Alcotest.run
    "keeper_volume_gc"
    [ ( "reclamation"
      , [ Alcotest.test_case "volume names parse back to their keeper" `Quick
            test_volume_names_parse_back_to_their_keeper
        ; Alcotest.test_case "the decision table keeps every protected volume" `Quick
            test_the_decision_table_keeps_every_protected_volume
        ; Alcotest.test_case "a report without execute touches nothing" `Quick
            test_a_report_without_execute_touches_nothing
        ; Alcotest.test_case "a failed deletion is reported" `Quick
            test_a_failed_deletion_is_reported
        ; Alcotest.test_case "a work volume that appears after the verdict preserves the keeper" `Quick
            test_build_only_cleanup_preserves_a_keeper_whose_work_volume_appeared
        ; Alcotest.test_case "a build volume that vanishes before the delete preserves the keeper" `Quick
            test_build_only_cleanup_preserves_a_keeper_whose_build_volume_vanished
        ; Alcotest.test_case "a failed delete-time confirmation preserves the keeper" `Quick
            test_build_only_cleanup_preserves_a_keeper_whose_confirmation_fails
        ; Alcotest.test_case "without an image there is no claim evidence" `Quick
            test_without_an_image_there_is_no_claim_evidence
        ; Alcotest.test_case "an unreadable claims marker keeps the volumes" `Quick
            test_an_unreadable_claims_marker_keeps_the_volumes
        ; Alcotest.test_case "a failed volume listing is an error" `Quick
            test_a_failed_volume_listing_is_an_error_and_nothing_runs
        ; Alcotest.test_case "a malformed initial listing starts nothing" `Quick
            test_a_malformed_initial_listing_never_starts_reclamation
        ; Alcotest.test_case "a malformed settling listing does not prove reclamation" `Quick
            test_a_malformed_settling_listing_does_not_prove_reclamation
        ] )
    ]
;;
