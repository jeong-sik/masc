module Input = Masc_tui_message_input
module Layout = Masc_tui_message_layout
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

let paste_and_word_delete () =
  let draft = Input.create () in
  Input.insert draft "one two!";
  Input.move_left draft;
  Input.delete_word draft;
  Input.insert draft "three\nfour";
  check string "paste and word erase act at cursor" "one three\nfour!" (Input.contents draft);
  check int "paste leaves cursor before retained suffix" (String.length "one three\nfour") (Input.cursor draft)

let viewport_tracks_cursor () =
  let text = "first\nsecond\nthird\nfourth\nfifth\nlast" in
  let start = Layout.composer_window ~max_rows:3 ~max_cells:20 ~cursor:0 text in
  check (list string) "start remains visible" ["first"; "second"; "third"] start.lines;
  check int "first row cursor" 0 start.cursor_row;
  check int "first column cursor" 0 start.cursor_cells;
  let last = Layout.composer_window ~max_rows:3 ~max_cells:20 ~cursor:(String.length text) text in
  check (list string) "end remains visible" ["fourth"; "fifth"; "last"] last.lines;
  check int "last row cursor" 2 last.cursor_row;
  check int "last column cursor" 4 last.cursor_cells;
  let text = "가나다라마바사아자차" in
  List.iter (fun cursor ->
    let visible, cells = Layout.input_window ~max_cells:8 ~cursor text in
    check bool "visible text remains UTF-8" true (String.is_valid_utf_8 visible);
    check bool "row fits" true (Layout.display_width visible <= 8);
    check bool "caret fits" true (cells < 8)) [0; 3; 15; String.length text]

let () = run "Chat composer cursor"
  [ "editing", [ test_case "empty Left boundary" `Quick empty_boundary;
                  test_case "Unicode insertion and erasure" `Quick unicode_editing;
                  test_case "paste and word erasure at cursor" `Quick paste_and_word_delete ];
    "rendering", [test_case "multiline and horizontal cursor viewport" `Quick viewport_tracks_cursor] ]
