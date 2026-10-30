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
    Input.append draft " ";
    Input.append draft "hello";
    check string "voice continues the whole draft" "world hello" (Input.contents draft);
    check int "voice leaves caret after the transcript" (String.length "world hello") (Input.cursor draft);
    Input.insert draft "!";
    check string "typing continues after voice" "world hello!" (Input.contents draft))
    [5, 0; 2, 3];
  let draft = Input.create () in
  Input.append draft "안녕🙂";
  check string "voice can start an empty draft" "안녕🙂" (Input.contents draft);
  check int "Unicode transcript ends at its byte boundary" (String.length "안녕🙂") (Input.cursor draft)

let () = run "Chat composer cursor"
  [ "editing", [ test_case "empty Left boundary" `Quick empty_boundary;
                  test_case "Unicode insertion and erasure" `Quick unicode_editing;
                  test_case "joined emoji and combining marks" `Quick joined_emoji;
                  test_case "paste and word erasure at cursor" `Quick paste_and_word_delete;
                  test_case "voice appends after cursor movement" `Quick voice_append_after_cursor_movement ];
    "rendering", [] ]
