open Alcotest

module Chat_diff = Masc_tui_keeper_chat_diff
module Transcript = Masc_tui_keeper_chat_transcript
module Evidence = Masc.Keeper_file_change_evidence

let contains ~needle text =
  let needle_length = String.length needle in
  let text_length = String.length text in
  let rec at index =
    index + needle_length <= text_length
    && (String.equal (String.sub text index needle_length) needle || at (index + 1))
  in
  needle_length > 0 && at 0

let change_json ?(keeper = "alpha") ?(execution_id = Some "exec-edit-1")
    ?(path = "lib/example.ml") ?(succeeded = true)
    ?(line_evidence = `Null)
    ?(kind = `Edit ("let answer = 41", "let answer = 42", false)) () =
  let identity =
    match execution_id with
    | None -> []
    | Some execution_id -> [ "execution_id", `String execution_id ]
  in
  let change =
    match kind with
    | `Edit (before, after, replace_all) ->
        `Assoc
          [ "kind", `String "edit"
          ; "before", `String before
          ; "after", `String after
          ; "replace_all", `Bool replace_all
          ]
    | `Write content ->
        `Assoc [ "kind", `String "write"; "content", `String content ]
    | `Materialize (sha256, bytes) ->
        `Assoc
          [ "kind", `String "materialize"
          ; "sha256", `String sha256
          ; "bytes", `Int bytes
          ]
  in
  `Assoc
    ([ "at", `Float 1.0
     ; "keeper", `String keeper
     ; "turn", `Int 7
     ; "task_id", `String "task-1"
     ; "line_evidence", line_evidence
     ]
    @ identity
    @ [ ( "location"
        , `Assoc
            [ "kind", `String "repo"
            ; "repo_id", `String "masc"
            ; "path", `String path
            ] )
      ; "change", change
      ; "succeeded", `Bool succeeded
      ])

let snapshot_json changes =
  `Assoc
    [ "keeper", `String "alpha"
    ; "window_hours", `Float 24.0
    ; "calls_in_window", `Int (List.length changes)
    ; "changes", `List changes
    ; "over_budget", `Int 0
    ; "malformed", `Int 0
    ]

let activity_snapshot_json changes =
  `Assoc
    [ "schema", `String "masc.ide.file_activity.v1"
    ; "codebase", `String "github.com_jeong-sik_masc"
    ; "repo_id", `String "masc"
    ; "file_path", `String "lib/example.ml"
    ; "window_hours", `Float 24.0
    ; "calls_in_window", `Int 44
    ; "changes", `List changes
    ; "incomplete_over_budget", `Int 3
    ; "incomplete_malformed", `Int 1
    ; "unattributed_over_budget", `Int 2
    ; "unattributed_malformed", `Int 1
    ]

let replace_field key value = function
  | `Assoc fields -> `Assoc ((key, value) :: List.remove_assoc key fields)
  | _ -> invalid_arg "replace_field expects an object"

let snapshot changes =
  match Masc.Tui_decode.decode_file_change_snapshot (snapshot_json changes) with
  | Ok snapshot -> snapshot
  | Error detail -> fail detail

let index changes =
  (snapshot changes).Masc.Tui_decode.fcs_changes |> Chat_diff.index

let activity ?execution_id ?(call_id = Some "provider-call-1") () =
  Transcript.make_tool_activity ?execution_id ~call_id ~tool_name:"Edit"
    ~args:"{\"file_path\":\"lib/example.ml\"}"
    ~outcome:Transcript.Returned ~duration:(Some "12ms") ()

let projection mode activities =
  Transcript.tool_block activities |> Transcript.project_tool_block mode

let projected_rows ?(max_line_cells = 96) mode indexed activities =
  let projected = projection mode activities in
  Chat_diff.rows ~mode ~max_line_cells indexed projected

let body rows = String.concat "\n" rows

let test_canonical_execution_identity_joins () =
  let indexed = index [ change_json () ] in
  match Chat_diff.associate indexed (activity ~execution_id:"exec-edit-1" ()) with
  | Chat_diff.Exact _ -> ()
  | Chat_diff.No_recorded_change -> fail "canonical execution id did not join"
  | Chat_diff.Ambiguous count -> failf "canonical id matched %d changes" count
;;

let test_provider_identity_never_authorizes_a_join () =
  let indexed = index [ change_json () ] in
  match
    Chat_diff.associate indexed
      (activity ~call_id:(Some "exec-edit-1") ())
  with
  | Chat_diff.No_recorded_change -> ()
  | Chat_diff.Exact _ -> fail "provider call id authorized a file-change join"
  | Chat_diff.Ambiguous count -> failf "provider id matched %d changes" count
;;

let test_repeated_canonical_identity_is_ambiguous () =
  let indexed =
    index
      [ change_json ()
      ; change_json ~kind:(`Write "second body") ()
      ]
  in
  check int "ambiguous canonical id groups" 1
    (Chat_diff.ambiguous_execution_ids indexed);
  match Chat_diff.associate indexed (activity ~execution_id:"exec-edit-1" ()) with
  | Chat_diff.Ambiguous 2 -> ()
  | Chat_diff.Ambiguous count -> failf "expected two candidates, got %d" count
  | Chat_diff.No_recorded_change -> fail "duplicate execution id was dropped"
  | Chat_diff.Exact _ -> fail "duplicate execution id was guessed"
;;

let test_missing_canonical_identity_is_counted () =
  let indexed = index [ change_json ~execution_id:None () ] in
  check int "unjoinable row count" 1
    (Chat_diff.missing_execution_ids indexed);
  match Chat_diff.associate indexed (activity ~execution_id:"exec-edit-1" ()) with
  | Chat_diff.No_recorded_change -> ()
  | Chat_diff.Exact _ -> fail "missing canonical id was invented"
  | Chat_diff.Ambiguous count -> failf "missing id matched %d changes" count
;;

let test_mixed_keeper_snapshot_is_rejected () =
  match
    Masc.Tui_decode.decode_file_change_snapshot
      (snapshot_json [ change_json ~keeper:"beta" () ])
  with
  | Error detail ->
      check bool "both keeper stamps are named" true
        (contains ~needle:"keeper beta inside snapshot for alpha" detail)
  | Ok _ -> fail "mixed-Keeper file-change snapshot was accepted"
;;

let test_file_activity_accepts_multiple_keepers_at_one_address () =
  match
    Masc.Tui_decode.decode_file_activity_snapshot
      (activity_snapshot_json
         [ change_json ~keeper:"alpha" (); change_json ~keeper:"beta" () ])
  with
  | Error detail -> fail detail
  | Ok snapshot ->
    check int "two exact changes" 2 (List.length snapshot.fas_changes);
    check int "exact-address incomplete rows remain visible" 3
      snapshot.fas_incomplete_over_budget;
    check int "unattributed budget rows remain visible" 2
      snapshot.fas_unattributed_over_budget
;;

let test_file_activity_rejects_a_change_from_another_file () =
  match
    Masc.Tui_decode.decode_file_activity_snapshot
      (activity_snapshot_json [ change_json ~path:"lib/other.ml" () ])
  with
  | Error detail ->
    check bool "mixed address is named" true
      (contains ~needle:"outside its declared repository address" detail)
  | Ok _ -> fail "mixed-address file activity was accepted"
;;

let test_unknown_change_kind_is_rejected () =
  let change =
    change_json ()
    |> replace_field "change" (`Assoc [ "kind", `String "patch" ])
  in
  match Masc.Tui_decode.decode_file_change_snapshot (snapshot_json [ change ]) with
  | Error detail ->
      check bool "unknown change tag is named" true
        (contains ~needle:"unknown file change kind \"patch\"" detail)
  | Ok _ -> fail "unknown file-change kind was accepted"
;;

let test_unknown_location_kind_is_rejected () =
  let change =
    change_json ()
    |> replace_field "location"
         (`Assoc [ "kind", `String "workspace"; "path", `String "example.ml" ])
  in
  match Masc.Tui_decode.decode_file_change_snapshot (snapshot_json [ change ]) with
  | Error detail ->
      check bool "unknown location tag is named" true
        (contains ~needle:"unknown file change location kind \"workspace\"" detail)
  | Ok _ -> fail "unknown file-change location kind was accepted"
;;

let test_malformed_change_object_is_rejected () =
  let change = change_json () |> replace_field "change" (`String "edit") in
  match Masc.Tui_decode.decode_file_change_snapshot (snapshot_json [ change ]) with
  | Error detail ->
      check bool "malformed change field is named" true
        (contains ~needle:"field 'change' must be an object" detail)
  | Ok _ -> fail "malformed file-change object was accepted"
;;

let test_target_line_comes_from_producer_evidence () =
  let line_evidence =
    `Assoc
      [ "kind", `String "edit"
      ; "occurrence_count", `Int 1
      ; ( "occurrences"
        , `List
            [ `Assoc
                [ ( "old_range"
                  , `Assoc [ "start_line", `Int 9; "end_line", `Int 10 ] )
                ; ( "new_range"
                  , `Assoc [ "start_line", `Int 9; "end_line", `Int 11 ] )
                ]
            ] )
      ]
  in
  let change =
    (snapshot [ change_json ~line_evidence () ]).Masc.Tui_decode.fcs_changes
    |> List.hd
  in
  check int "producer line, not replacement-text search" 9
    (Masc.Tui_decode.file_change_target_line change)
;;

let test_target_line_without_evidence_is_the_visible_top () =
  let change = (snapshot [ change_json () ]).Masc.Tui_decode.fcs_changes |> List.hd in
  check int "historical row does not guess" 1
    (Masc.Tui_decode.file_change_target_line change)
;;

let test_mismatched_or_unjoinable_evidence_is_rejected () =
  let write_evidence = Evidence.written "body" |> Evidence.to_yojson in
  let edit_evidence =
    Evidence.edited
      [ Evidence.edit_occurrence
          ~old_start_line:1
          ~new_start_line:1
          ~old_string:"old"
          ~new_string:"new"
      ]
    |> Evidence.to_yojson
  in
  let two_occurrences =
    Evidence.edited
      [ Evidence.edit_occurrence
          ~old_start_line:1
          ~new_start_line:1
          ~old_string:"old"
          ~new_string:"new"
      ; Evidence.edit_occurrence
          ~old_start_line:3
          ~new_start_line:3
          ~old_string:"old"
          ~new_string:"new"
      ]
    |> Evidence.to_yojson
  in
  let cases =
    [ ( "kind mismatch"
      , change_json ~line_evidence:write_evidence () )
    ; ( "missing execution id"
      , change_json
          ~execution_id:None
          ~line_evidence:write_evidence
          ~kind:(`Write "body")
          () )
    ; ( "failed mutation"
      , change_json
          ~succeeded:false
          ~line_evidence:edit_evidence
          () )
    ; ( "single Edit count"
      , change_json ~line_evidence:two_occurrences () )
    ]
  in
  List.iter
    (fun (label, change) ->
       match
         Masc.Tui_decode.decode_file_change_snapshot
           (snapshot_json [ change ])
       with
       | Error _ -> ()
       | Ok _ -> failf "%s evidence was accepted" label)
    cases
;;

let test_terminal_controls_are_sanitized_before_markdown () =
  let rows =
    projected_rows Transcript.Full
      (index [ change_json ~kind:(`Edit ("old", "\027[31mred", false)) () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "terminal escape is absent" false
    (contains ~needle:"\027" (body rows))
;;

let () =
  run "tui_keeper_chat_diff"
    [ ( "identity"
      , [ test_case "canonical execution id" `Quick
            test_canonical_execution_identity_joins
        ; test_case "provider id is correlation only" `Quick
            test_provider_identity_never_authorizes_a_join
        ; test_case "duplicate canonical id is ambiguous" `Quick
            test_repeated_canonical_identity_is_ambiguous
        ; test_case "missing canonical id is counted" `Quick
            test_missing_canonical_identity_is_counted
        ; test_case "mixed keeper snapshot is rejected" `Quick
            test_mixed_keeper_snapshot_is_rejected
        ; test_case "file activity accepts multiple keepers" `Quick
            test_file_activity_accepts_multiple_keepers_at_one_address
        ; test_case "file activity rejects another file" `Quick
            test_file_activity_rejects_a_change_from_another_file
        ; test_case "unknown change kind is rejected" `Quick
            test_unknown_change_kind_is_rejected
        ; test_case "unknown location kind is rejected" `Quick
            test_unknown_location_kind_is_rejected
        ; test_case "malformed change object is rejected" `Quick
            test_malformed_change_object_is_rejected
        ; test_case "producer evidence owns the target line" `Quick
            test_target_line_comes_from_producer_evidence
        ; test_case "historical row opens at the top" `Quick
            test_target_line_without_evidence_is_the_visible_top
        ; test_case "mismatched or unjoinable evidence is rejected" `Quick
            test_mismatched_or_unjoinable_evidence_is_rejected
        ] )
    ; ( "projection"
      , [ test_case "terminal controls are sanitized" `Quick
            test_terminal_controls_are_sanitized_before_markdown
        ] )
    ]
;;
