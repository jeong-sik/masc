(** Tests for [Keeper_tool_call_file_change].

    The fixtures are shaped after rows the live log actually holds
    (~/.masc/tool_calls/2026-08/*.jsonl, read 2026-08-24), not after the
    writer's source: the projection's job is to read what is on disk, and a
    fixture derived from the writer would pass even if the two drifted. *)

open Alcotest
open Masc

module Change = Keeper_tool_call_file_change
module Evidence = Keeper_file_change_evidence

(* One logged call. Only the fields the projection reads are spelled; a real
   row carries about thirty more, and listing them here would make the test
   about the writer's schema instead of about what the reader needs. *)
let row ?(keeper = "fixture-keeper") ?(descriptor_id = "agent.edit_file")
    ?(target_path = "repos/masc/test/test_ci_run_tests_script.ml") ?(success = true)
    ?(turn = Some 2459) ?(task_id = Some "task-475")
    ?(execution_id = Some "exec-1787533327603-0173") ?line_evidence
    ?(ts = 1787533327.603755) input =
  let optional name = function None -> [] | Some value -> [ (name, value) ] in
  `Assoc
    ([ ("ts", `Float ts)
     ; ("keeper", `String keeper)
     ; ("input", input)
     ; ("success", `Bool success)
     ; ("route_evidence", `Assoc [ ("descriptor_id", `String descriptor_id) ])
     ; ("action_radius", `Assoc [ ("target_path", `String target_path) ])
    ]
    @ optional "turn" (Option.map (fun t -> `Int t) turn)
    @ optional "task_id" (Option.map (fun t -> `String t) task_id)
    @ optional "execution_id" (Option.map (fun id -> `String id) execution_id)
    @ optional "file_change_evidence" line_evidence)
;;

let edit_input ?(replace_all = None) ~before ~after () =
  let optional = match replace_all with None -> [] | Some b -> [ ("replace_all", `Bool b) ] in
  `Assoc ([ ("file_path", `String "test/x.ml"); ("old_string", `String before)
          ; ("new_string", `String after) ] @ optional)
;;

let classify row = Change.classify row

let change_of row =
  match classify row with
  | Change.File_change change -> change
  | Change.Not_a_file_change -> fail "expected a file change, got Not_a_file_change"
  | Change.Unreadable _ -> fail "expected a file change, got Unreadable"
;;

(* An edit keeps both sides of the swap. This is the whole reason the
   projection exists: the durable transcript drops the arguments, and this is
   where the before/after text still is. *)
let test_edit_carries_both_sides () =
  let change = change_of (row (edit_input ~before:"let x = 1" ~after:"let x = 2" ())) in
  match change.Change.kind with
  | Change.Edited { before; after; replace_all } ->
      check string "before" "let x = 1" before;
      check string "after" "let x = 2" after;
      check bool "replace_all defaults to one occurrence" false replace_all
  | Change.Written _ -> fail "expected Edited"
;;

let test_edit_reads_replace_all () =
  let change =
    change_of (row (edit_input ~replace_all:(Some true) ~before:"a" ~after:"b" ()))
  in
  match change.Change.kind with
  | Change.Edited { replace_all; _ } -> check bool "replace_all" true replace_all
  | Change.Written _ -> fail "expected Edited"
;;

let test_write_carries_content () =
  let change =
    change_of
      (row ~descriptor_id:"agent.write_file"
         (`Assoc [ ("file_path", `String "x.ml"); ("content", `String "whole body") ]))
  in
  match change.Change.kind with
  | Change.Written { content } -> check string "content" "whole body" content
  | Change.Edited _ -> fail "expected Written"
;;

let test_edit_carries_producer_line_evidence_through_redaction () =
  let original_secret =
    List.init 9 (fun index -> Printf.sprintf "secret-%d" index)
    |> String.concat "\n"
  in
  let evidence =
    Evidence.edited
      [ Evidence.edit_occurrence
          ~old_start_line:12
          ~new_start_line:12
          ~old_string:original_secret
          ~new_string:"safe"
      ]
  in
  let change =
    change_of
      (row
         ~line_evidence:(Evidence.to_yojson evidence)
         (edit_input ~before:"[REDACTED]" ~after:"safe" ()))
  in
  let projected = Change.to_json change in
  check string "same typed evidence reaches the endpoint"
    (Evidence.to_yojson evidence |> Yojson.Safe.to_string)
    (Yojson.Safe.Util.member "line_evidence" projected
     |> Yojson.Safe.to_string)
;;

let test_legacy_row_has_no_invented_line_evidence () =
  let change =
    change_of (row (edit_input ~before:"old" ~after:"new" ()))
  in
  check bool "historical row remains range-less" true
    (Option.is_none change.Change.line_evidence)
;;

let test_oversized_edit_keeps_count_and_explicitly_omits_ranges () =
  let occurrence_count = Evidence.max_recorded_edit_occurrences + 1 in
  let evidence = Evidence.edited_ranges_omitted ~occurrence_count in
  let change =
    change_of
      (row
         ~line_evidence:(Evidence.to_yojson evidence)
         (edit_input
            ~replace_all:(Some true)
            ~before:"old"
            ~after:"new"
            ()))
  in
  match change.Change.line_evidence with
  | Some (Evidence.Edited { occurrence_count = actual; occurrences = None }) ->
    check int "exact count" occurrence_count actual
  | _ -> fail "expected bounded Edit evidence"
;;

let expect_malformed label row =
  match classify row with
  | Change.Unreadable (Change.Malformed _) -> ()
  | Change.Unreadable Change.Input_exceeded_log_budget ->
    failf "%s: expected malformed evidence, got log budget" label
  | Change.File_change _ -> failf "%s: malformed evidence was accepted" label
  | Change.Not_a_file_change -> failf "%s: file change was classified as a read" label
;;

let test_invalid_file_change_evidence_is_rejected () =
  let edit_evidence =
    Evidence.edited
      [ Evidence.edit_occurrence
          ~old_start_line:2
          ~new_start_line:2
          ~old_string:"old"
          ~new_string:"new"
      ]
    |> Evidence.to_yojson
  in
  expect_malformed
    "kind mismatch"
    (row
       ~descriptor_id:"agent.write_file"
       ~line_evidence:edit_evidence
       (`Assoc [ "file_path", `String "x.ml"; "content", `String "body" ]));
  expect_malformed
    "failed mutation"
    (row
       ~success:false
       ~line_evidence:edit_evidence
       (edit_input ~before:"old" ~after:"new" ()));
  expect_malformed
    "missing execution identity"
    (row
       ~execution_id:None
       ~line_evidence:edit_evidence
       (edit_input ~before:"old" ~after:"new" ()));
  expect_malformed
    "count mismatch"
    (row
       ~line_evidence:
         (`Assoc
           [ "kind", `String "edit"
           ; "occurrence_count", `Int 1
           ; "occurrences", `List []
           ])
       (edit_input ~before:"old" ~after:"new" ()));
  expect_malformed
    "invalid line range"
    (row
       ~line_evidence:
         (`Assoc
           [ "kind", `String "edit"
           ; "occurrence_count", `Int 1
           ; ( "occurrences"
             , `List
                 [ `Assoc
                     [ ( "old_range"
                       , `Assoc
                           [ "start_line", `Int 4; "end_line", `Int 3 ] )
                     ; ( "new_range"
                       , `Assoc
                           [ "start_line", `Int 4; "end_line", `Int 4 ] )
                     ] ] )
           ])
       (edit_input ~before:"old" ~after:"new" ()));
  expect_malformed
    "Write range does not start at one"
    (row
       ~descriptor_id:"agent.write_file"
       ~line_evidence:
         (`Assoc
           [ "kind", `String "write"
           ; ( "new_range"
             , `Assoc [ "start_line", `Int 42; "end_line", `Int 43 ] )
           ])
       (`Assoc [ "file_path", `String "x.ml"; "content", `String "body" ]))
;;

(* The address comes from the resolver's target, so a file inside a clone is
   named the way the same file is named in anyone else's checkout. *)
let test_repo_relative_address () =
  let change = change_of (row (edit_input ~before:"a" ~after:"b" ())) in
  match change.Change.location with
  | Change.In_repo { repo_id; relative_path } ->
      check string "repo" "masc" repo_id;
      check string "path" "test/test_ci_run_tests_script.ml" relative_path
  | Change.In_bundle { bundle_path } -> failf "expected In_repo, got bundle %s" bundle_path
  | Change.At_absolute_path { path } -> failf "expected In_repo, got absolute %s" path
;;

(* A scratch file in the playground root is still a file the keeper wrote.
   Dropping it would undercount the turn; coercing it into a repository would
   name a file that no checkout has. *)
let test_outside_a_repo_is_kept_as_bundle () =
  let change =
    change_of
      (row ~descriptor_id:"agent.write_file" ~target_path:"verify-468.sh"
         (`Assoc [ ("content", `String "#!/bin/sh\n") ]))
  in
  match change.Change.location with
  | Change.In_bundle { bundle_path } -> check string "bundle path" "verify-468.sh" bundle_path
  | Change.In_repo { repo_id; _ } -> failf "expected In_bundle, got repo %s" repo_id
  | Change.At_absolute_path { path } -> failf "expected In_bundle, got absolute %s" path
;;

(* The resolver sometimes records an absolute path — 40 of 568 changes over
   2026-08-22..24, in two shapes. Neither is repository-addressable, and
   calling either a bundle path would name a file under a bundle root it does
   not sit in. *)
let absolute_location description target_path =
  let change = change_of (row ~target_path (edit_input ~before:"a" ~after:"b" ())) in
  match change.Change.location with
  | Change.At_absolute_path { path } -> check string description target_path path
  | Change.In_repo { repo_id; relative_path } ->
      failf "expected an absolute path, got repo %s / %s" repo_id relative_path
  | Change.In_bundle { bundle_path } ->
      failf "an absolute path is not relative to a bundle: %s" bundle_path
;;

(* A worktree checked out at the bundle's own level rather than under
   [repos/] — the shape #28968 describes. *)
let test_absolute_worktree_checkout () =
  absolute_location "worktree checkout"
    "/Users/dancer/me/.masc/playground/polisher/masc-task238/lib/keeper/keeper_gate.ml"
;;

(* A write into the operator's own tree, outside any playground. *)
let test_absolute_outside_any_playground () =
  absolute_location "operator tree"
    "/Users/dancer/me/workspace/yousleepwhen/masc/lib/dashboard/dashboard_events.ml"
;;

let test_metadata_round_trip () =
  let change = change_of (row (edit_input ~before:"a" ~after:"b" ())) in
  check string "keeper" "fixture-keeper" change.Change.keeper;
  check (option int) "turn" (Some 2459) change.Change.turn;
  check (option string) "task" (Some "task-475") change.Change.task_id;
  check bool "succeeded" true change.Change.succeeded
;;

let test_producer_line_evidence_reaches_projection () =
  let evidence =
    Keeper_file_change_evidence.edited
      [ Keeper_file_change_evidence.edit_occurrence
          ~old_start_line:9
          ~new_start_line:9
          ~old_string:"old\nline"
          ~new_string:"new\nline\nextra"
      ]
  in
  let change =
    change_of
      (row
         ~line_evidence:(Keeper_file_change_evidence.to_yojson evidence)
         (edit_input ~before:"old\nline" ~after:"new\nline\nextra" ()))
  in
  match change.Change.line_evidence with
  | Some actual ->
    check string "typed evidence survives"
      (Keeper_file_change_evidence.to_yojson evidence |> Yojson.Safe.to_string)
      (Keeper_file_change_evidence.to_yojson actual |> Yojson.Safe.to_string);
    check bool "wire projection carries evidence" true
      (Yojson.Safe.Util.member "line_evidence" (Change.to_json change)
       = Keeper_file_change_evidence.to_yojson evidence)
  | None -> fail "producer evidence was dropped"
;;

let test_malformed_line_evidence_is_unreadable () =
  match
    classify
      (row
         ~line_evidence:
           (`Assoc
             [ "kind", `String "edit"
             ; "occurrence_count", `Int 1
             ; "occurrences", `List []
             ])
         (edit_input ~before:"old" ~after:"new" ()))
  with
  | Change.Unreadable (Change.Malformed detail) ->
    check bool "evidence failure is named" true
      (String_util.contains_substring detail "file_change_evidence")
  | Change.Unreadable Change.Input_exceeded_log_budget ->
    fail "malformed evidence is not an input budget problem"
  | Change.File_change _ -> fail "malformed evidence was accepted"
  | Change.Not_a_file_change -> fail "an edit became a read"
;;

let test_line_evidence_kind_must_match_the_tool () =
  match
    classify
      (row
         ~line_evidence:
           (`Assoc
             [ "kind", `String "write"
             ; ( "new_range"
               , `Assoc [ "start_line", `Int 1; "end_line", `Int 1 ] )
             ])
         (edit_input ~before:"old" ~after:"new" ()))
  with
  | Change.Unreadable (Change.Malformed detail) ->
    check bool "kind drift is named" true
      (String_util.contains_substring detail "edit input carries write")
  | Change.Unreadable Change.Input_exceeded_log_budget ->
    fail "kind drift is not an input budget problem"
  | Change.File_change _ -> fail "mismatched producer evidence was accepted"
  | Change.Not_a_file_change -> fail "an edit became a read"
;;

(* A write that failed is a change the keeper attempted. Filtering it out here
   would make a turn that fought a file look like a turn that never touched
   it. *)
let test_failed_write_is_still_projected () =
  let change =
    change_of
      (row ~descriptor_id:"agent.write_file" ~success:false
         (`Assoc [ ("content", `String "x") ]))
  in
  check bool "succeeded" false change.Change.succeeded
;;

let test_read_is_not_a_change () =
  match classify (row ~descriptor_id:"agent.read_file" (`Assoc [ ("file_path", `String "x.ml") ])) with
  | Change.Not_a_file_change -> ()
  | Change.File_change _ -> fail "a read is not a file change"
  | Change.Unreadable _ -> fail "a read should classify, not come back Unreadable"
;;

(* Memory writes carry a [content] field of their own. Keying on the field
   would have swept them in; keying on the descriptor does not. *)
let test_memory_write_is_not_a_file_change () =
  match
    classify (row ~descriptor_id:"keeper.memory.write" (`Assoc [ ("content", `String "note") ]))
  with
  | Change.Not_a_file_change -> ()
  | Change.File_change _ -> fail "a memory write does not touch a file in the tree"
  | Change.Unreadable _ -> fail "expected Not_a_file_change, got Unreadable"
;;

let test_memory_retract_is_not_a_file_change () =
  match
    classify
      (row
         ~descriptor_id:"keeper.memory.retract"
         (`Assoc
             [ "memory_id", `String ("sha256:" ^ String.make 64 '0')
             ; "reason", `String "incorrect"
             ]))
  with
  | Change.Not_a_file_change -> ()
  | Change.File_change _ -> fail "a memory retraction does not touch a file in the tree"
  | Change.Unreadable _ -> fail "expected Not_a_file_change, got Unreadable"
;;

(* A file-writing call whose arguments did not survive is reported, not
   silently dropped. A caller that saw [Not_a_file_change] here would count a
   producer defect as a read. *)
let test_edit_missing_arguments_is_unreadable () =
  match classify (row (`Assoc [ ("file_path", `String "x.ml") ])) with
  | Change.Unreadable (Change.Malformed _) -> ()
  | Change.Unreadable Change.Input_exceeded_log_budget ->
      fail "a present-but-incomplete object is not a budget problem"
  | Change.File_change _ -> fail "an edit with no strings is not a readable change"
  | Change.Not_a_file_change -> fail "an edit is a file-writing call even when unreadable"
;;

let test_unknown_descriptor_is_unreadable () =
  match classify (row ~descriptor_id:"agent.invented_by_a_future_build" (edit_input ~before:"a" ~after:"b" ())) with
  | Change.Unreadable (Change.Malformed _) -> ()
  | Change.Unreadable Change.Input_exceeded_log_budget ->
      fail "an unknown descriptor is not a budget problem"
  | Change.File_change _ -> fail "an unknown descriptor cannot be read as a change"
  | Change.Not_a_file_change -> fail "an unknown descriptor is not known to be a read"
;;

let test_missing_action_radius_is_unreadable () =
  let bare =
    `Assoc
      [ ("ts", `Float 1.)
      ; ("keeper", `String "fixture-keeper")
      ; ("input", edit_input ~before:"a" ~after:"b" ())
      ; ("route_evidence", `Assoc [ ("descriptor_id", `String "agent.edit_file") ])
      ]
  in
  match classify bare with
  | Change.Unreadable (Change.Malformed _) -> ()
  | Change.Unreadable Change.Input_exceeded_log_budget ->
      fail "a missing action_radius is not a budget problem"
  | Change.File_change _ -> fail "a change with no resolved target has no address"
  | Change.Not_a_file_change -> fail "it is still a file-writing call"
;;

(* Measured on the live log: 10 of 182 file-writing calls on 2026-08-24 had
   their whole [input] flattened to a preview string, because
   [Keeper_tool_call_log.input_to_json] does that once the serialized
   arguments pass 4,000 bytes. The change is real and its text is gone. An
   operator seeing "3 changes too large to show" can read that; the same three
   counted as parse failures would send someone hunting a bug. *)
let test_input_flattened_by_the_log_budget () =
  match classify (row (`String "{\"file_path\":\"x.ml\",\"old_string\":\"aaa...(truncated)")) with
  | Change.Unreadable Change.Input_exceeded_log_budget -> ()
  | Change.Unreadable (Change.Malformed detail) ->
      failf "a flattened input is the log's budget, not a defect: %s" detail
  | Change.File_change _ -> fail "the text is not on disk to be read back"
  | Change.Not_a_file_change -> fail "it is still a file-writing call"
;;

(* Composition-surface tools carry no descriptor at all — [log_call] says so.
   Three such rows a day would otherwise inflate the unreadable count and make
   a healthy log look broken. *)
let test_row_without_route_evidence_is_not_a_change () =
  let bare =
    `Assoc
      [ ("ts", `Float 1.)
      ; ("keeper", `String "fixture-keeper")
      ; ("tool", `String "keeper_compose_mission-snapshot")
      ; ("input", `Assoc [ ("content", `String "x") ])
      ]
  in
  match classify bare with
  | Change.Not_a_file_change -> ()
  | Change.File_change _ -> fail "a composition surface does not write to the tree"
  | Change.Unreadable _ -> fail "a tool with no descriptor is not a defect"
;;

(* The counts are the caller's, not a log line: a route that answers with
   changes should be able to say how many rows it could not read. *)
let test_classify_all_counts_each_outcome () =
  let rows =
    [ row (edit_input ~before:"a" ~after:"b" ())
    ; row ~descriptor_id:"agent.read_file" (`Assoc [ ("file_path", `String "x.ml") ])
    ; row (`Assoc [ ("file_path", `String "x.ml") ])
    ]
  in
  let tally = Change.classify_all rows in
  check int "changes" 1 (List.length tally.Change.changes);
  check int "not file changes" 1 tally.Change.not_file_changes;
  check int "malformed" 1 tally.Change.malformed;
  check int "over budget" 0 tally.Change.over_budget
;;

let test_classify_all_preserves_order () =
  let rows =
    [ row (edit_input ~before:"first" ~after:"1" ())
    ; row (edit_input ~before:"second" ~after:"2" ())
    ]
  in
  let changes = (Change.classify_all rows).Change.changes in
  let befores =
    List.map
      (fun (c : Change.t) ->
        match c.Change.kind with Change.Edited { before; _ } -> before | Change.Written _ -> "")
      changes
  in
  check (list string) "order" [ "first"; "second" ] befores
;;

let test_repo_file_filter_is_exact_and_preserves_order () =
  let rows =
    [ row ~keeper:"alpha" ~target_path:"repos/masc/bin/a.ml"
        (edit_input ~before:"first" ~after:"1" ())
    ; row ~keeper:"beta" ~target_path:"repos/other/bin/a.ml"
        (edit_input ~before:"other repo" ~after:"2" ())
    ; row ~keeper:"gamma" ~target_path:"repos/masc/bin/b.ml"
        (edit_input ~before:"other file" ~after:"3" ())
    ; row ~keeper:"delta" ~target_path:"repos/masc/bin/a.ml"
        (edit_input ~before:"second" ~after:"4" ())
    ; row ~keeper:"epsilon" ~target_path:"scratch/bin/a.ml"
        (edit_input ~before:"bundle" ~after:"5" ())
    ]
  in
  let changes = (Change.classify_all rows).Change.changes in
  let filtered =
    Change.for_repo_file ~repo_id:"masc" ~relative_path:"bin/a.ml" changes
  in
  check (list string) "keepers in source order" [ "alpha"; "delta" ]
    (List.map (fun change -> change.Change.keeper) filtered)
;;

let test_unreadable_filter_uses_independent_resolved_target () =
  let rows =
    [ row ~target_path:"repos/masc/bin/a.ml" (`String "oversized input preview")
    ; row ~target_path:"repos/masc/bin/b.ml" (`String "other oversized preview")
    ]
  in
  let tally = Change.classify_all rows in
  check int "both rows exceed the inline budget" 2 tally.Change.over_budget;
  let filtered =
    Change.unreadable_for_repo_file ~repo_id:"masc"
      ~relative_path:"bin/a.ml" tally.Change.unreadable_rows
  in
  check int "only the exact resolved target" 1 (List.length filtered);
  match (List.hd filtered).Change.ur_reason with
  | Change.Input_exceeded_log_budget -> ()
  | Change.Malformed detail -> failf "expected log budget, got %s" detail
;;

let () =
  run "keeper_tool_call_file_change"
    [ ( "kind"
      , [ test_case "edit carries both sides" `Quick test_edit_carries_both_sides
        ; test_case "edit reads replace_all" `Quick test_edit_reads_replace_all
        ; test_case "write carries content" `Quick test_write_carries_content
        ; test_case "edit evidence survives redacted text" `Quick
            test_edit_carries_producer_line_evidence_through_redaction
        ; test_case "legacy rows do not invent evidence" `Quick
            test_legacy_row_has_no_invented_line_evidence
        ; test_case "oversized edit evidence keeps its count" `Quick
            test_oversized_edit_keeps_count_and_explicitly_omits_ranges
        ] )
    ; ( "address"
      , [ test_case "repo-relative" `Quick test_repo_relative_address
        ; test_case "outside a repo stays a bundle path" `Quick test_outside_a_repo_is_kept_as_bundle
        ; test_case "absolute worktree checkout" `Quick test_absolute_worktree_checkout
        ; test_case "absolute outside any playground" `Quick test_absolute_outside_any_playground
        ] )
    ; ( "metadata"
      , [ test_case "round trip" `Quick test_metadata_round_trip
        ; test_case "producer line evidence reaches projection" `Quick
            test_producer_line_evidence_reaches_projection
        ; test_case "malformed line evidence is unreadable" `Quick
            test_malformed_line_evidence_is_unreadable
        ; test_case "line evidence kind matches the tool" `Quick
            test_line_evidence_kind_must_match_the_tool
        ; test_case "failed write is projected" `Quick test_failed_write_is_still_projected
        ] )
    ; ( "not a change"
      , [ test_case "read" `Quick test_read_is_not_a_change
        ; test_case "memory retract" `Quick test_memory_retract_is_not_a_file_change
        ; test_case "memory write" `Quick test_memory_write_is_not_a_file_change
        ; test_case "no route evidence" `Quick test_row_without_route_evidence_is_not_a_change
        ] )

    ; ( "unreadable"
      , [ test_case "input flattened by the log budget" `Quick test_input_flattened_by_the_log_budget
        ; test_case "edit with no strings" `Quick test_edit_missing_arguments_is_unreadable
        ; test_case "unknown descriptor" `Quick test_unknown_descriptor_is_unreadable
        ; test_case "no resolved target" `Quick test_missing_action_radius_is_unreadable
        ; test_case "invalid line evidence" `Quick
            test_invalid_file_change_evidence_is_rejected
        ] )
    ; ( "classify_all"
      , [ test_case "counts each outcome" `Quick test_classify_all_counts_each_outcome
        ; test_case "preserves order" `Quick test_classify_all_preserves_order
        ; test_case "repo file filter is exact" `Quick
            test_repo_file_filter_is_exact_and_preserves_order
        ; test_case "unreadable filter uses resolved target" `Quick
            test_unreadable_filter_uses_independent_resolved_target
        ] )
    ]
;;
