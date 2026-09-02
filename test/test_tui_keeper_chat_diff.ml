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

let test_full_projection_weaves_recorded_replacement () =
  let rows =
    projected_rows Transcript.Full (index [ change_json () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check (list string) "historical Full rows are byte-compatible"
    [ "✓ Edit lib/example.ml · 12ms"
    ; "↳ masc:lib/example.ml (+1 -1)"
    ; "  recorded replacement"
    ; "```diff"
    ; "-let answer = 41"
    ; "+let answer = 42"
    ; "```"
    ]
    rows;
  let body = body rows in
  List.iter
    (fun needle ->
      check bool ("body contains " ^ needle) true (contains ~needle body))
    [ "✓ Edit lib/example.ml · 12ms"
    ; "↳ masc:lib/example.ml (+1 -1)"
    ; "recorded replacement"
    ; "```diff"
    ; "-let answer = 41"
    ; "+let answer = 42"
    ];
  check bool "historical row does not invent a line range" false
    (contains ~needle:"old L" body)
;;

let test_full_projection_shows_actual_edit_range () =
  let evidence =
    Evidence.edited
      [ Evidence.edit_occurrence
          ~old_start_line:42
          ~new_start_line:42
          ~old_string:"old a\nold b"
          ~new_string:"new a\nnew b\nnew c"
      ]
    |> Evidence.to_yojson
  in
  let rows =
    projected_rows Transcript.Full
      (index
         [ change_json
             ~line_evidence:evidence
             ~kind:
               (`Edit
                 ( "old a\nold b"
                 , "new a\nnew b\nnew c"
                 , false ))
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "producer range sits beside the recorded replacement" true
    (contains ~needle:"old L42-43 -> new L42-44" (body rows))
;;

let test_replace_all_shows_bounded_actual_ranges () =
  let occurrence old_start new_start =
    Evidence.edit_occurrence
      ~old_start_line:old_start
      ~new_start_line:new_start
      ~old_string:"old"
      ~new_string:"new\nextra"
  in
  let evidence =
    Evidence.edited
      [ occurrence 2 2
      ; occurrence 5 6
      ; occurrence 8 10
      ; occurrence 13 16
      ]
    |> Evidence.to_yojson
  in
  let rows =
    projected_rows Transcript.Full
      (index
         [ change_json
             ~line_evidence:evidence
             ~kind:(`Edit ("old", "new\nextra", true))
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let body = body rows in
  List.iter
    (fun needle ->
       check bool ("body contains " ^ needle) true (contains ~needle body))
    [ "4 matches"
    ; "#1 old L2 -> new L2-3"
    ; "#3 old L8 -> new L10-11"
    ; "1 more recorded line range withheld"
    ];
  check bool "fourth range is not rendered inline" false
    (contains ~needle:"old L13 -> new L16-17" body)
;;

let test_omitted_ranges_keep_count_without_inventing_coordinates () =
  let occurrence_count = Evidence.max_recorded_edit_occurrences + 1 in
  let evidence =
    Evidence.edited_ranges_omitted ~occurrence_count |> Evidence.to_yojson
  in
  let rows =
    projected_rows Transcript.Full
      (index
         [ change_json
             ~line_evidence:evidence
             ~kind:(`Edit ("old", "new", true))
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let body = body rows in
  check bool "exact match count remains visible" true
    (contains
       ~needle:
         (Printf.sprintf "%d matches · line ranges omitted" occurrence_count)
       body);
  check bool "no line coordinate is invented" false
    (contains ~needle:"old L" body)
;;

let test_deletion_and_write_ranges_are_explicit () =
  let deletion =
    Evidence.edited
      [ Evidence.edit_occurrence
          ~old_start_line:7
          ~new_start_line:7
          ~old_string:"delete me\n"
          ~new_string:""
      ]
    |> Evidence.to_yojson
  in
  let deletion_rows =
    projected_rows Transcript.Full
      (index
         [ change_json
             ~line_evidence:deletion
             ~kind:(`Edit ("delete me\n", "", false))
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "deletion has no fabricated new coordinate" true
    (contains ~needle:"old L7 -> deleted" (body deletion_rows));
  let write = Evidence.written "first\nsecond\n" |> Evidence.to_yojson in
  let write_rows =
    projected_rows Transcript.Full
      (index
         [ change_json
             ~line_evidence:write
             ~kind:(`Write "first\nsecond\n")
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "Write names only its new full-body range" true
    (contains ~needle:"new L1-2" (body write_rows))
;;

let test_narrow_evidence_rows_keep_the_authoritative_fact () =
  let occurrence_count = Evidence.max_recorded_edit_occurrences + 1 in
  let omitted =
    Evidence.edited_ranges_omitted ~occurrence_count |> Evidence.to_yojson
  in
  let omitted_rows =
    projected_rows ~max_line_cells:24 Transcript.Full
      (index
         [ change_json
             ~line_evidence:omitted
             ~kind:(`Edit ("old", "new", true))
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let count_label = Printf.sprintf "%d matches" occurrence_count in
  let omitted_evidence_row =
    match List.find_opt (contains ~needle:count_label) omitted_rows with
    | Some row -> row
    | None -> failf "narrow Edit dropped %s" count_label
  in
  let write = Evidence.written "first\nsecond\n" |> Evidence.to_yojson in
  let write_rows =
    projected_rows ~max_line_cells:24 Transcript.Full
      (index
         [ change_json
             ~line_evidence:write
             ~kind:(`Write "first\nsecond\n")
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let write_evidence_row =
    match List.find_opt (contains ~needle:"new L1-2") write_rows with
    | Some row -> row
    | None -> fail "narrow Write dropped new L1-2"
  in
  List.iter
    (fun row ->
       check bool "narrow evidence row fits its cell budget" true
         (Masc_tui_message_layout.display_width row <= 24))
    [ omitted_evidence_row; write_evidence_row ]
;;

let test_compact_projection_is_byte_unchanged () =
  let indexed = index [ change_json () ] in
  let projected =
    projection Transcript.Compact [ activity ~execution_id:"exec-edit-1" () ]
  in
  check (list string) "compact rows"
    projected.Transcript.rows
    (Chat_diff.rows ~mode:Transcript.Compact ~max_line_cells:96 indexed projected)
;;

let test_write_states_unknown_previous_content () =
  let rows =
    projected_rows Transcript.Full
      (index [ change_json ~kind:(`Write "first\nsecond") () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let body = body rows in
  check bool "unknown before is explicit" true
    (contains ~needle:"previous content unavailable" body);
  check bool "written row count stays with the path" true
    (contains ~needle:"↳ masc:lib/example.ml (2 rows written)" body);
  check bool "write is not presented as an exact diff" false
    (contains ~needle:"```diff" body);
  check bool "recorded body remains visible" true
    (contains ~needle:"first\nsecond" body)
;;

let test_failed_write_is_labelled_as_an_attempt () =
  let rows =
    projected_rows Transcript.Full
      (index
         [ change_json ~succeeded:false ~kind:(`Write "first\nsecond") () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let body = body rows in
  check bool "failed write does not claim rows were written" false
    (contains ~needle:"rows written" body);
  check bool "failed write keeps its recorded body size" true
    (contains ~needle:"↳ masc:lib/example.ml (2-row write attempt)" body);
  check bool "failed attempt remains explicit" true
    (contains ~needle:"failed attempt" body)
;;

let test_replace_all_states_unknown_match_count () =
  let rows =
    projected_rows Transcript.Full
      (index [ change_json ~kind:(`Edit ("old", "new", true)) () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let body = body rows in
  check bool "replace-all size stays per match" true
    (contains ~needle:"↳ masc:lib/example.ml (+1 -1 per match)" body);
  check bool "replace-all count is not invented" true
    (contains ~needle:"match count unavailable" body)
;;

let test_long_path_keeps_the_change_size_visible () =
  let rows =
    projected_rows ~max_line_cells:40 Transcript.Full
      (index
         [ change_json
             ~path:"lib/아주/긴/🙂/directory/that/keeps/going/example.ml"
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let heading = List.find (fun row -> String.starts_with ~prefix:"↳ " row) rows in
  check bool "the path keeps both ends" true
    (contains ~needle:"…" heading && contains ~needle:"example.ml" heading);
  check bool "the typed size survives path clipping" true
    (contains ~needle:"(+1 -1)" heading);
  check bool "the heading fits its cell budget" true
    (Masc_tui_message_layout.display_width heading <= 40)
;;

let test_narrow_unicode_path_keeps_the_change_size_visible () =
  let rows =
    projected_rows ~max_line_cells:24 Transcript.Full
      (index
         [ change_json
             ~path:"lib/아주/긴/🙂/directory/that/keeps/going/example.ml"
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let heading = List.find (fun row -> String.starts_with ~prefix:"↳ " row) rows in
  check bool "the narrow path is middle-fitted" true (contains ~needle:"…" heading);
  check bool "the narrow heading keeps the typed size" true
    (contains ~needle:"(+1 -1)" heading);
  check bool "the narrow heading fits its cell budget" true
    (Masc_tui_message_layout.display_width heading <= 24)
;;

let test_source_lines_are_cell_bounded () =
  let rows =
    projected_rows ~max_line_cells:12 Transcript.Full
      (index [ change_json ~kind:(`Edit ("old", String.make 80 'n', false)) () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let added =
    List.find (fun row -> String.length row > 0 && row.[0] = '+') rows
  in
  check bool "clipped row carries omission mark" true
    (contains ~needle:"…" added);
  check bool "one source row fits the cell budget" true
    (Masc_tui_message_layout.display_width added <= 12)
;;

let test_long_change_states_exact_source_omission () =
  let content =
    List.init 15 (fun index -> Printf.sprintf "new-%02d" index)
    |> String.concat "\n"
  in
  let rows =
    projected_rows Transcript.Full
      (index [ change_json ~kind:(`Write content) () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "omitted source rows are counted" true
    (contains ~needle:"3 more recorded rows" (body rows))
;;

let test_block_caps_inline_previews () =
  let changes, activities =
    List.init 4 (fun index ->
      let execution_id = Printf.sprintf "exec-%d" index in
      ( change_json ~execution_id:(Some execution_id) ()
      , activity ~execution_id () ))
    |> List.split
  in
  let body = projected_rows Transcript.Full (index changes) activities |> body in
  check bool "the fourth preview is summarized" true
    (contains ~needle:"1 more recorded-change annotation withheld" body)
;;

let test_fence_collision_counts_withheld_rows () =
  let rows =
    projected_rows Transcript.Full
      (index
         [ change_json
             ~kind:(`Edit ("```\n~~~\nold", "```\n~~~\nnew", false))
             ()
         ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "withheld preview row count is explicit" true
    (contains ~needle:"4 recorded preview rows withheld" (body rows))
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

let test_typed_activity_details_follow_their_tool_row () =
  let activities =
    [ activity ~execution_id:"exec-1" (); activity ~execution_id:"exec-2" () ]
  in
  let rows =
    Chat_diff.rows ~mode:Transcript.Full ~max_line_cells:96
      ~activity_details:(fun activity ->
        [ "detail " ^ Option.value ~default:"missing" activity.execution_id ])
      Chat_diff.empty (projection Transcript.Full activities)
  in
  match rows with
  | first :: first_detail :: second :: second_detail :: [] ->
      check bool "first tool row" true (contains ~needle:"✓ Edit" first);
      check string "first detail follows it" "detail exec-1" first_detail;
      check bool "second tool row" true (contains ~needle:"✓ Edit" second);
      check string "second detail follows it" "detail exec-2" second_detail
  | _ -> failf "tool details lost per-activity hierarchy: %s" (body rows)
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
      , [ test_case "full projection weaves replacement" `Quick
            test_full_projection_weaves_recorded_replacement
        ; test_case "actual Edit range" `Quick
            test_full_projection_shows_actual_edit_range
        ; test_case "replace-all range annotations are bounded" `Quick
            test_replace_all_shows_bounded_actual_ranges
        ; test_case "omitted ranges keep count only" `Quick
            test_omitted_ranges_keep_count_without_inventing_coordinates
        ; test_case "deletion and Write ranges" `Quick
            test_deletion_and_write_ranges_are_explicit
        ; test_case "narrow evidence keeps authoritative facts" `Quick
            test_narrow_evidence_rows_keep_the_authoritative_fact
        ; test_case "compact projection is unchanged" `Quick
            test_compact_projection_is_byte_unchanged
        ; test_case "typed details follow each tool row" `Quick
            test_typed_activity_details_follow_their_tool_row
        ; test_case "write states unknown before" `Quick
            test_write_states_unknown_previous_content
        ; test_case "failed write is an attempt" `Quick
            test_failed_write_is_labelled_as_an_attempt
        ; test_case "replace-all states unknown count" `Quick
            test_replace_all_states_unknown_match_count
        ; test_case "long path keeps the change size" `Quick
            test_long_path_keeps_the_change_size_visible
        ; test_case "narrow Unicode path keeps the change size" `Quick
            test_narrow_unicode_path_keeps_the_change_size_visible
        ; test_case "source rows are bounded" `Quick
            test_source_lines_are_cell_bounded
        ; test_case "source omission is exact" `Quick
            test_long_change_states_exact_source_omission
        ; test_case "block preview count is bounded" `Quick
            test_block_caps_inline_previews
        ; test_case "fence collision counts withheld rows" `Quick
            test_fence_collision_counts_withheld_rows
        ; test_case "terminal controls are sanitized" `Quick
            test_terminal_controls_are_sanitized_before_markdown
        ] )
    ]
;;
