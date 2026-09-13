(** The help overlay scrolls against the sheet it draws.

    The overlay writes its lines one per row and then, on a terminal wide
    enough, folds them into two columns -- so the rows it draws are half the
    lines it holds. The key handler used to bound [j] with the line count and
    no height at all, which let the stored scroll run to twice what the frame
    could ever show. The reader saw the sheet stop, kept pressing, and then
    had to press [k] dozens of times before anything moved.

    These tests pin the two numbers both sides now read. *)

let check_int = Alcotest.(check int)
let check_bool = Alcotest.(check bool)
let check_string = Alcotest.(check string)

(* Stand-ins for the real sections. A plain run of lines is one section; the
   sheet the overlay draws is headings and their rows, each ended by a blank
   line, the way [help_lines] writes them. *)
let lines n = List.init n (fun i -> Printf.sprintf "line %d" i)

let sectioned ~sections ~rows =
  List.concat
    (List.init sections (fun s ->
         (Printf.sprintf "heading %d" s
          :: List.init (rows - 1) (fun r -> Printf.sprintf "section %d row %d" s r))
         @ [ "" ]))

let test_wide_terminal_pairs_whole_sections () =
  let sheet = Masc_tui_help.sheet ~cols:120 (sectioned ~sections:4 ~rows:18) in
  check_int "four 18-row sections fold into two pairs and a gap" 37
    (List.length sheet)

let test_odd_line_count_keeps_the_tail () =
  let sheet = Masc_tui_help.sheet ~cols:120 (sectioned ~sections:3 ~rows:18) in
  check_int "a third section sits alone under the pair" 37 (List.length sheet);
  let contains needle haystack =
    let n = String.length needle and h = String.length haystack in
    let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
    go 0
  in
  check_bool "the lone section keeps its last row" true
    (contains "section 2 row 16" (List.nth sheet 36))

(* A column cut at a line count started partway through a section, so the top
   of the right column was keys under no heading. Each row now starts a
   section on both sides or continues the one above it. *)
let test_a_heading_stays_above_its_rows () =
  let starts_with prefix text =
    let text = String.trim text in
    String.length text >= String.length prefix
    && String.sub text 0 (String.length prefix) = prefix
  in
  let sheet =
    Masc_tui_help.sheet ~cols:120
      [ "heading A"; "a1"; "a2"; ""; "heading B"; "b1"; ""; "heading C"; "c1"; "" ]
  in
  check_int "A and B side by side (3), a gap (1), then C (2)" 6 (List.length sheet);
  let first = List.hd sheet in
  let right_column = String.sub first 59 (String.length first - 59) in
  check_bool "the first row opens both sections" true
    (starts_with "heading A" first && starts_with "heading B" right_column);
  check_bool "the third section starts its own row" true
    (starts_with "heading C" (List.nth sheet 4))

let test_narrow_terminal_draws_one_line_per_row () =
  let sheet = Masc_tui_help.sheet ~cols:80 (lines 76) in
  check_int "an 80-column terminal draws every line on its own row" 76
    (List.length sheet)

let test_header_prepends_full_width_without_folding () =
  let header = [ "banner line 1"; "banner line 2" ] in
  let sheet = Masc_tui_help.sheet ~header ~cols:120 (sectioned ~sections:4 ~rows:18) in
  check_int "header rows (2) + folded body (37) = 39 rows" 39 (List.length sheet);
  check_string "first row is banner line 1" "banner line 1" (List.hd sheet);
  check_string "second row is banner line 2" "banner line 2" (List.nth sheet 1)

(* The frame's rows, asked of the module that draws it. *)
let test_content_height_leaves_room_for_the_frame () =
  check_int "a 43-row viewport draws 38 rows of sheet" 38
    (Masc_tui_frame.content_height ~rows:43);
  check_int "a viewport smaller than the frame still draws one row" 1
    (Masc_tui_frame.content_height ~rows:2)

(* What the key handler and the drawing both do now. *)
let viewport ~cols ~rows lines =
  ( List.length (Masc_tui_help.sheet ~cols lines)
  , Masc_tui_frame.content_height ~rows )

let test_holding_j_does_not_bank_presses () =
  let count, height = viewport ~cols:120 ~rows:30 (sectioned ~sections:4 ~rows:18) in
  let ceiling = Masc_tui_scroll.maximum ~count ~height in
  let rec press_down n scroll =
    if n = 0 then scroll
    else press_down (n - 1) (Masc_tui_scroll.down ~count ~height scroll)
  in
  let bottom = press_down 200 0 in
  check_int "j stops at the last row the frame can show" ceiling bottom;
  check_bool "one k moves the frame straight away" true
    (Masc_tui_scroll.up ~count ~height bottom < ceiling)

let test_the_line_count_is_not_the_bound () =
  (* The number the old ceiling used, against the one the frame can spend. *)
  let sheet_lines = sectioned ~sections:4 ~rows:18 in
  let count, height = viewport ~cols:120 ~rows:30 sheet_lines in
  check_bool "a bound taken from the lines overshoots the sheet" true
    (List.length sheet_lines - 1 > Masc_tui_scroll.maximum ~count ~height)

let test_narrow_terminal_with_header () =
  let header = [ "banner 1"; "banner 2"; "banner 3" ] in
  let sheet = Masc_tui_help.sheet ~header ~cols:80 (lines 20) in
  check_int "narrow terminal: header rows (3) + body rows (20) = 23 rows" 23
    (List.length sheet);
  check_string "first row is banner 1" "banner 1" (List.hd sheet)

let test_help_sections_marks_current_surface_with_here_marker () =
  let sections_with_current =
    Masc_tui_keys.help_sections ~current:Masc_tui_types.Board ()
  in
  (match sections_with_current with
   | [] -> Alcotest.fail "sections should not be empty"
   | (title, _) :: _ ->
       check_bool "current surface section ends with here_marker" true
         (String.ends_with ~suffix:Masc_tui_keys.here_marker title);
       let marker_len = String.length Masc_tui_keys.here_marker in
       let base = String.sub title 0 (String.length title - marker_len) in
       check_string "base title is Board" "Board" base);
  let sections_without_current = Masc_tui_keys.help_sections () in
  (match sections_without_current with
   | [] -> Alcotest.fail "sections should not be empty"
   | (title, _) :: _ ->
       check_string "unspecified surface opens with Global" "Global" title;
       check_bool "global section has no here_marker" false
         (String.ends_with ~suffix:Masc_tui_keys.here_marker title))

let () =
  Alcotest.run "tui_help_scroll"
    [ ( "sheet"
      , [ Alcotest.test_case "wide terminal pairs whole sections" `Quick
            test_wide_terminal_pairs_whole_sections
        ; Alcotest.test_case "odd line count keeps the tail" `Quick
            test_odd_line_count_keeps_the_tail
        ; Alcotest.test_case "a heading stays above its rows" `Quick
            test_a_heading_stays_above_its_rows
        ; Alcotest.test_case "narrow terminal draws one line per row" `Quick
            test_narrow_terminal_draws_one_line_per_row
        ; Alcotest.test_case "header prepends full width without folding" `Quick
            test_header_prepends_full_width_without_folding
        ; Alcotest.test_case "narrow terminal with header draws all rows" `Quick
            test_narrow_terminal_with_header
        ; Alcotest.test_case "content height leaves room for the frame" `Quick
            test_content_height_leaves_room_for_the_frame
        ] )
    ; ( "keys_and_sections"
      , [ Alcotest.test_case "help_sections marks current surface with here_marker" `Quick
            test_help_sections_marks_current_surface_with_here_marker
        ] )
    ; ( "bound"
      , [ Alcotest.test_case "holding j does not bank presses" `Quick
            test_holding_j_does_not_bank_presses
        ; Alcotest.test_case "the line count is not the bound" `Quick
            test_the_line_count_is_not_the_bound
        ] )
    ]
