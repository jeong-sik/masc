module Input = Masc_tui_message_input
open Alcotest

let empty_boundary () =
  let draft = Input.create () in
  check bool "empty input hands Left to the navigator" true (Input.can_leave_left draft);
  Input.insert draft "ab";
  Input.move_left draft;
  Input.move_left draft;
  Input.move_left draft;
  check int "cursor stops at start" 0 (Input.cursor draft);
  check bool "nonempty input keeps Left even at start" false (Input.can_leave_left draft);
  Input.insert draft "x";
  check string "insertion at start" "xab" (Input.contents draft);
  Input.clear draft;
  check bool "clear restores the escape boundary" true (Input.can_leave_left draft)

let unicode_editing () =
  let draft = Input.create () in
  Input.insert draft "가나🙂";
  Input.move_left draft;
  Input.backspace draft;
  Input.insert draft "다";
  check string "edit before emoji without splitting UTF-8" "가다🙂" (Input.contents draft);
  check int "cursor after inserted Korean scalar" 6 (Input.cursor draft);
  Input.move_right draft;
  Input.move_right draft;
  check int "Right stops at end" (String.length "가다🙂") (Input.cursor draft);
  check bool "valid UTF-8 remains" true (String.is_valid_utf_8 (Input.contents draft))

let joined_emoji () =
  let draft = Input.create () in
  Input.insert draft "👩‍💻X";
  Input.move_left draft;
  check int "before trailing X" (String.length "👩‍💻") (Input.cursor draft);
  Input.move_left draft;
  check int "Left crosses the complete ZWJ grapheme" 0 (Input.cursor draft);
  Input.move_right draft;
  Input.backspace draft;
  check string "Backspace removes the whole visible emoji" "X" (Input.contents draft);
  Input.insert draft "é";
  Input.backspace draft;
  check string "combining mark follows its base" "X" (Input.contents draft)

let paste_and_word_delete () =
  let draft = Input.create () in
  Input.insert draft "one two!";
  Input.move_left draft;
  Input.delete_word draft;
  Input.insert draft "three\nfour";
  check string "paste and word erase act at cursor" "one three\nfour!" (Input.contents draft);
  check int "paste leaves cursor before retained suffix" (String.length "one three\nfour") (Input.cursor draft)

let voice_append_after_cursor_movement () =
  List.iter (fun (left_steps, expected_cursor) ->
    let draft = Input.create () in
    Input.insert draft "world";
    for _ = 1 to left_steps do Input.move_left draft done;
    check int "editing cursor before voice completes" expected_cursor (Input.cursor draft);
    Input.append_separated draft ~separator:" " "hello";
    check string "voice continues the whole draft" "world hello" (Input.contents draft);
    check int "voice leaves caret after the transcript" (String.length "world hello") (Input.cursor draft);
    Input.insert draft "!";
    check string "typing continues after voice" "world hello!" (Input.contents draft))
    [5, 0; 2, 3];
  let draft = Input.create () in
  Input.append_separated draft ~separator:" " "안녕🙂";
  check string "voice can start an empty draft" "안녕🙂" (Input.contents draft);
  check int "Unicode transcript ends at its byte boundary" (String.length "안녕🙂") (Input.cursor draft)

let revision_tracks_edits_but_not_cursor_moves () =
  let draft = Input.create () and other = Input.create () in
  let original = Input.revision draft in
  check bool "revision belongs to one input" false (Input.has_revision other original);
  Input.move_left draft;
  Input.move_right draft;
  check bool "cursor moves do not invalidate an edit" true (Input.has_revision draft original);
  Input.insert draft "";
  check bool "even an empty insert invalidates the old edit" false (Input.has_revision draft original);
  let current = Input.revision draft in
  Input.backspace draft;
  check bool "backspace at the beginning invalidates the old edit" false (Input.has_revision draft current);
  let current = Input.revision draft in
  Input.invalidate_revision draft;
  check bool "attachment changes can invalidate the old edit" false (Input.has_revision draft current)

let boundary_changes_across_insertions () =
  let draft = Input.create () in
  Input.insert draft "eX";
  Input.move_left draft;
  Input.insert draft "\xcc\x81";
  check string "combining mark joins the earlier scalar" "e\xcc\x81X" (Input.contents draft);
  check int "cursor follows the joined grapheme" (String.length "e\xcc\x81") (Input.cursor draft);
  Input.backspace draft;
  check string "backspace removes the joined grapheme" "X" (Input.contents draft);
  Input.clear draft;
  Input.insert draft "A\r\nB";
  Input.move_left draft;
  Input.move_left draft;
  check int "CRLF remains one grapheme" 1 (Input.cursor draft);
  Input.move_right draft;
  check int "right crosses both CRLF bytes" 3 (Input.cursor draft)

let cursor_after_appended_text () =
  let draft = Input.create () in
  Input.append draft "abc";
  let revision = Input.revision draft in
  Input.move_left draft;
  check int "left after append" 2 (Input.cursor draft);
  check bool "classifying appended text keeps the revision" true (Input.has_revision draft revision);
  Input.backspace draft;
  check string "backspace after append uses the cursor" "ac" (Input.contents draft);
  Input.clear draft;
  Input.append draft "\xc3";
  Input.append draft "\xa9";
  Input.move_left draft;
  check int "split UTF-8 append joins into one grapheme" 0 (Input.cursor draft);
  Input.move_right draft;
  check int "right crosses the completed UTF-8 scalar" 2 (Input.cursor draft);
  Input.clear draft;
  Input.append draft "a\x1b[31mX";
  Input.move_left draft;
  Input.move_left draft;
  check int "left crosses the whole ANSI sequence" 1 (Input.cursor draft);
  Input.move_right draft;
  check int "right crosses the whole ANSI sequence" 6 (Input.cursor draft)

let separated_append_keeps_exact_bytes () =
  let draft = Input.create () in
  let original = Input.revision draft in
  Input.append_separated draft ~separator:"/" "";
  check string "empty draft receives no separator" "" (Input.contents draft);
  check bool "empty append still invalidates the revision" false
    (Input.has_revision draft original);
  Input.append_separated draft ~separator:"/" "가";
  Input.append_separated draft ~separator:"/" "";
  Input.append_separated draft ~separator:"\000" "\255";
  check string "separator and payload retain their bytes" "가/\000\255" (Input.contents draft);
  check int "cursor stays at the end" (String.length "가/\000\255") (Input.cursor draft)

let move_to_start draft =
  while Input.cursor draft > 0 do Input.move_left draft done

let current_owned_view draft owner = Input.snapshot_owned_view (Input.snapshot draft) owner

let expanded draft owner replacement =
  match current_owned_view draft owner with
  | None -> Input.contents draft
  | Some view -> Input.replace_owned view ~replacement

let owned_literal_provenance () =
  let draft = Input.create () and marker = "[paste → source]" in
  let owner = Input.insert_owned draft marker in
  Input.insert draft (" tail " ^ marker);
  move_to_start draft;
  Input.insert draft (marker ^ "\n");
  check string "identical user text stays literal on both sides"
    (marker ^ "\nORIGINAL tail " ^ marker) (expanded draft owner "ORIGINAL");
  Input.move_left draft;
  Input.backspace draft;
  check bool "editing outside the owned extent keeps it" true
    (Option.is_some (current_owned_view draft owner))

let retired_owned_bytes_do_not_revive () =
  let draft = Input.create () and marker = "[original]" in
  let owner = Input.insert_owned draft marker in
  Input.backspace draft; Input.insert draft "]";
  check string "same bytes after an edit are literal" marker (expanded draft owner "UNWANTED");
  Input.clear draft; Input.insert draft marker;
  check string "clear and retype cannot revive ownership" marker (expanded draft owner "UNWANTED");
  let owner = Input.insert_owned draft marker in
  Input.delete_word draft;
  check bool "word erasure retires an overlapping span" true
    (Option.is_none (current_owned_view draft owner));
  Input.clear draft;
  let owner = Input.insert_owned draft marker in
  Input.append draft "́";
  Input.backspace draft; Input.insert draft "]";
  check string "grapheme erasure across owned boundary cannot revive equal bytes"
    marker (expanded draft owner "UNWANTED")

let deleted_owner_keeps_other_literal () =
  let draft = Input.create () and marker = "[paste]" in
  let owner = Input.insert_owned draft marker in
  move_to_start draft; Input.insert draft (marker ^ "\n");
  while Input.cursor draft < Input.length draft do Input.move_right draft done;
  while Input.cursor draft > String.length marker + 1 do Input.backspace draft done;
  check string "removing the real owner cannot expand another copy"
    (marker ^ "\n") (expanded draft owner "UNWANTED")

let owned_utf8_boundary_edits () =
  let draft = Input.create () in
  Input.insert draft "한\n";
  let owner = Input.insert_owned draft "[원문]" in
  Input.append_separated draft ~separator:"\n" "👩‍💻";
  move_to_start draft; Input.insert draft "語 ";
  Input.delete_word draft;
  check string "word erasure before the span shifts its byte offset"
    "한\nPAYLOAD\n👩‍💻" (expanded draft owner "PAYLOAD");
  while Input.cursor draft < Input.length draft do Input.move_right draft done;
  Input.backspace draft;
  check string "grapheme erasure after the span keeps its ownership"
    "한\nPAYLOAD\n" (expanded draft owner "PAYLOAD");
  check bool "source stays valid UTF-8" true (String.is_valid_utf_8 (Input.contents draft))

let owned_snapshots_and_revision () =
  let draft = Input.create () in
  let owner = Input.insert_owned draft "[paste]" in
  let snapshot = Input.snapshot draft in
  let view = Option.get (Input.snapshot_owned_view snapshot owner) in
  Input.move_left draft;
  check bool "cursor movement preserves preparation" true (Input.owned_is_current draft view);
  Input.invalidate_revision draft;
  check bool "attachment revision refuses old preparation" false (Input.owned_is_current draft view);
  Input.clear draft;
  check bool "current snapshot does not resurrect retired owner" true
    (Option.is_none (Input.snapshot_owned_view (Input.snapshot draft) owner));
  let restored = Input.create () in
  Input.insert restored (Input.replace_owned view ~replacement:"ORIGINAL");
  check string "explicit saved-view restoration materializes the exact source" "ORIGINAL" (Input.contents restored);
  check bool "restored plain source does not acquire old handle" true
    (Option.is_none (current_owned_view restored owner))

let owned_parser_projection () =
  let module Command = Masc_tui_command in
  let draft = Input.create () and marker = "[paste]" in
  Input.insert draft ("/steer  " ^ marker ^ "  \n");
  let owner = Input.insert_owned draft marker in
  Input.insert draft "\n尾";
  let command, ranges = Command.parse_with_message_source (Input.contents draft) in
  check bool "same parser chooses steer without interpreting original bytes" true
    (command = Command.Steer_turn (marker ^ "\n" ^ marker ^ "\n尾"));
  let view = Option.get (Input.project_owned (Option.get (current_owned_view draft owner)) (Option.get ranges)) in
  check string "projection trims command spaces while preserving original payload whitespace/slash"
    (marker ^ "\n  /help\n原文  \n尾")
    (Input.replace_owned view ~replacement:"  /help\n原文  ");
  check bool "projection keeps input revision authority" true (Input.owned_is_current draft view);
  Input.insert draft "new";
  check bool "projected preparation becomes stale after edit" false (Input.owned_is_current draft view)

let owned_plain_message_is_not_reparsed () =
  let module Command = Masc_tui_command in
  let draft = Input.create () in
  let owner = Input.insert_owned draft "[paste]" in
  let command, ranges = Command.parse_with_message_source (Input.contents draft) in
  check bool "visible input determines Say" true (command = Command.Say "[paste]");
  let view = Option.get (Input.project_owned (Option.get (current_owned_view draft owner)) (Option.get ranges)) in
  check string "slash in original stays message data" "/help\ntext"
    (Input.replace_owned view ~replacement:"/help\ntext");
  let _, other = Command.parse_with_message_source "/task title\n[paste]" in
  check bool "another command exposes no message-data projection" true (Option.is_none other)

(* These are saved draft bytes and edit ownership, not terminal rows. Cache
   reuse must survive tail edits and be retired when segmentation can change. *)
let retained_boundaries_follow_replacement_text () =
  let draft = Input.create () in
  Input.insert draft "앞é🙂x";
  Input.move_left draft;
  Input.move_right draft;
  Input.backspace draft;
  Input.backspace draft;
  Input.insert draft "👩‍💻";
  Input.backspace draft;
  Input.backspace draft;
  check string "tail edits retain the complete earlier Korean scalar" "앞"
    (Input.snapshot_text (Input.snapshot draft));
  Input.clear draft;
  Input.insert draft "éX\255";
  Input.move_left draft;
  Input.move_right draft;
  Input.backspace draft;
  Input.backspace draft;
  Input.backspace draft;
  check string "removing invalid UTF8 resegments the newly valid prefix" ""
    (Input.snapshot_text (Input.snapshot draft));
  Input.append draft "\xc3";
  Input.move_left draft;
  Input.append draft "\xa9";
  Input.backspace draft;
  check string "completing UTF8 replaces an earlier invalid-byte index" ""
    (Input.snapshot_text (Input.snapshot draft))

let middle_edits_resegment_the_whole_replacement () =
  let draft = Input.create () in
  Input.insert draft "🇦🇧🇨🇩🇪🇫";
  Input.move_left draft;
  Input.move_left draft;
  Input.insert draft "🇬";
  Input.backspace draft;
  check string "a middle RI changes the following pairs before deletion"
    "🇦🇧🇩🇪🇫" (Input.snapshot_text (Input.snapshot draft));
  Input.clear draft;
  let owner = Input.insert_owned draft "👩" in
  Input.insert draft "💻";
  Input.move_left draft;
  Input.insert draft "‍";
  let revision = Input.revision draft in
  Input.backspace draft;
  check string "joining across a middle insertion deletes the whole new cluster" ""
    (Input.snapshot_text (Input.snapshot draft));
  check bool "deletion invalidates the submitted edit revision" false
    (Input.has_revision draft revision);
  check bool "joined deletion retires its overlapped source owner" true
    (Option.is_none (current_owned_view draft owner))

let () = run "Chat composer cursor"
  [ "editing", [ test_case "empty Left boundary" `Quick empty_boundary;
                  test_case "Unicode insertion and erasure" `Quick unicode_editing;
                  test_case "joined emoji and combining marks" `Quick joined_emoji;
                  test_case "paste and word erasure at cursor" `Quick paste_and_word_delete;
                  test_case "voice appends after cursor movement" `Quick voice_append_after_cursor_movement;
                  test_case "revision follows edits" `Quick revision_tracks_edits_but_not_cursor_moves;
                  test_case "grapheme boundaries can change on insertion" `Quick boundary_changes_across_insertions;
                  test_case "cursor works after appended text" `Quick cursor_after_appended_text;
                  test_case "separated append retains exact bytes" `Quick separated_append_keeps_exact_bytes;
                  test_case "retained boundaries follow replacement text" `Quick retained_boundaries_follow_replacement_text;
                  test_case "middle edits resegment the replacement" `Quick middle_edits_resegment_the_whole_replacement;
                  test_case "owned extent ignores identical literals" `Quick owned_literal_provenance;
                  test_case "edited owner never revives" `Quick retired_owned_bytes_do_not_revive;
                  test_case "deleting owner leaves literal copies" `Quick deleted_owner_keeps_other_literal;
                  test_case "owned UTF-8 boundary edits" `Quick owned_utf8_boundary_edits;
                  test_case "owned snapshots and revision" `Quick owned_snapshots_and_revision;
                  test_case "actual steer source projection" `Quick owned_parser_projection;
                  test_case "plain spill is message data" `Quick owned_plain_message_is_not_reparsed ];
    "rendering", [] ]
