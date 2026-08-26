open Alcotest

module Chat_diff = Masc_tui_keeper_chat_diff
module Transcript = Masc_tui_keeper_chat_transcript

let contains ~needle text =
  let needle_length = String.length needle in
  let text_length = String.length text in
  let rec at index =
    index + needle_length <= text_length
    && (String.equal (String.sub text index needle_length) needle || at (index + 1))
  in
  needle_length > 0 && at 0

let change_json ?(keeper = "alpha") ?(execution_id = Some "exec-edit-1")
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
     ]
    @ identity
    @ [ ( "location"
        , `Assoc
            [ "kind", `String "repo"
            ; "repo_id", `String "masc"
            ; "path", `String "lib/example.ml"
            ] )
      ; "change", change
      ; "succeeded", `Bool true
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

let test_full_projection_weaves_recorded_replacement () =
  let rows =
    projected_rows Transcript.Full (index [ change_json () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  let body = body rows in
  List.iter
    (fun needle ->
      check bool ("body contains " ^ needle) true (contains ~needle body))
    [ "✓ Edit lib/example.ml · 12ms"
    ; "↳ masc:lib/example.ml"
    ; "recorded replacement · -1 +1"
    ; "```diff"
    ; "-let answer = 41"
    ; "+let answer = 42"
    ]
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
  check bool "write is not presented as an exact diff" false
    (contains ~needle:"```diff" body);
  check bool "recorded body remains visible" true
    (contains ~needle:"first\nsecond" body)
;;

let test_replace_all_states_unknown_match_count () =
  let rows =
    projected_rows Transcript.Full
      (index [ change_json ~kind:(`Edit ("old", "new", true)) () ])
      [ activity ~execution_id:"exec-edit-1" () ]
  in
  check bool "replace-all count is not invented" true
    (contains ~needle:"per match · match count unavailable" (body rows))
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
        ; test_case "unknown change kind is rejected" `Quick
            test_unknown_change_kind_is_rejected
        ; test_case "unknown location kind is rejected" `Quick
            test_unknown_location_kind_is_rejected
        ; test_case "malformed change object is rejected" `Quick
            test_malformed_change_object_is_rejected
        ] )
    ; ( "projection"
      , [ test_case "full projection weaves replacement" `Quick
            test_full_projection_weaves_recorded_replacement
        ; test_case "compact projection is unchanged" `Quick
            test_compact_projection_is_byte_unchanged
        ; test_case "write states unknown before" `Quick
            test_write_states_unknown_previous_content
        ; test_case "replace-all states unknown count" `Quick
            test_replace_all_states_unknown_match_count
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
