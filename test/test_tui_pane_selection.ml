open Alcotest
module Selection = Masc_tui_pane_selection
module Layout = Masc_tui_message_layout

(* Synthetic frames only: a roster, a surface and an Activity pane joined
   into each row, the way the render joins them. Nothing here is drawn by a
   real surface, so no rendered layout is pinned. *)
let roster_cols = 10
let main_cols = 30
let activity_cols = 10
let body_rows = 3
let first_body_row = 2
let strip_row = 1

let roster_split = { Selection.roster_cols; roster_rows = body_rows }

let layout =
  Selection.frame_layout ~first_row:first_body_row ~body_rows ~main_cols
    ~activity_cols ~roster:(Some roster_split)

let red = "\027[31m"
let dim = "\027[2m"
let reset = "\027[0m"

let pad text cells = text ^ String.make (cells - Layout.display_width text) ' '

let joined ~roster ~main ~activity =
  red ^ pad roster roster_cols ^ reset
  ^ pad main (main_cols - roster_cols)
  ^ dim ^ pad activity activity_cols ^ reset

let strip = "tab strip spans every pane"

let frame_rows =
  [ strip
  ; joined ~roster:"keeper-a" ~main:"first line" ~activity:"call 1"
  ; joined ~roster:"keeper-b" ~main:"second line" ~activity:"call 2"
  ; joined ~roster:"keeper-c" ~main:"third" ~activity:"call 3"
  ]

let main_left = roster_cols + 1
let activity_left = main_cols + 1

let kind_name = function
  | Selection.Roster -> "roster"
  | Selection.Main -> "main"
  | Selection.Activity -> "activity"

let kind_at ~row ~column =
  Option.map
    (fun (pane : Selection.pane) -> kind_name pane.kind)
    (Selection.pane_at layout ~row ~column)

let point row column = { Selection.row; column }

let contains text affix =
  let text_length = String.length text and affix_length = String.length affix in
  let rec from offset =
    offset + affix_length <= text_length
    && (String.equal (String.sub text offset affix_length) affix || from (offset + 1))
  in
  from 0

let show_outcome = function
  | Selection.Click { row; column } -> Printf.sprintf "click %d,%d" row column
  | Selection.Copy { anchor; focus; pane } ->
      Printf.sprintf "copy %s %d,%d-%d,%d" (kind_name pane.kind) anchor.row
        anchor.column focus.row focus.column
  | Selection.Nothing -> "nothing"

let gesture moves start =
  List.fold_left
    (fun gesture (row, column) -> Selection.drag gesture ~row ~column)
    start moves

let outcome ~press:(row, column) ~moves ~release:(release_row, release_column) =
  let pressed = Selection.press layout ~row ~column in
  show_outcome
    (Selection.release (gesture moves pressed) ~row:release_row
       ~column:release_column)

let selection_of ~press:(row, column) ~moves ~release:(release_row, release_column) =
  match
    Selection.release
      (gesture moves (Selection.press layout ~row ~column))
      ~row:release_row ~column:release_column
  with
  | Selection.Copy selection -> selection
  | (Selection.Click _ | Selection.Nothing) as other ->
      failf "expected a selection, got %s" (show_outcome other)

let test_pane_hit_uses_recorded_rectangles () =
  check (option string) "the strip row is in no pane" None
    (kind_at ~row:strip_row ~column:1);
  check (option string) "roster column" (Some "roster")
    (kind_at ~row:first_body_row ~column:roster_cols);
  check (option string) "first surface column" (Some "main")
    (kind_at ~row:first_body_row ~column:main_left);
  check (option string) "last surface column" (Some "main")
    (kind_at ~row:first_body_row ~column:main_cols);
  check (option string) "Activity column" (Some "activity")
    (kind_at ~row:first_body_row ~column:activity_left);
  check (option string) "past the Activity pane" None
    (kind_at ~row:first_body_row ~column:(main_cols + activity_cols + 1));
  check (option string) "below the body" None
    (kind_at ~row:(first_body_row + body_rows) ~column:main_left)

(* Rows below the roster span both the roster's columns and the surface's, so
   they belong to neither; the Activity pane runs the whole body. *)
let test_rows_below_the_roster_are_in_no_left_pane () =
  let shorter = { roster_split with roster_rows = body_rows - 1 } in
  let layout =
    Selection.frame_layout ~first_row:first_body_row ~body_rows ~main_cols
      ~activity_cols ~roster:(Some shorter)
  in
  let last_body_row = first_body_row + body_rows - 1 in
  let at ~column =
    Option.map
      (fun (pane : Selection.pane) -> kind_name pane.kind)
      (Selection.pane_at layout ~row:last_body_row ~column)
  in
  check (option string) "roster columns" None (at ~column:1);
  check (option string) "surface columns" None (at ~column:main_left);
  check (option string) "Activity pane" (Some "activity") (at ~column:activity_left)

let test_click_and_drag_are_told_apart () =
  let row = first_body_row and column = main_left + 2 in
  check string "release where it was pressed" (Printf.sprintf "click %d,%d" row column)
    (outcome ~press:(row, column) ~moves:[] ~release:(row, column));
  check string "a motion report on the pressed cell is still a click"
    (Printf.sprintf "click %d,%d" row column)
    (outcome ~press:(row, column) ~moves:[ (row, column) ] ~release:(row, column));
  check string "a move makes it a selection"
    (Printf.sprintf "copy main %d,%d-%d,%d" row column row (column + 4))
    (outcome ~press:(row, column) ~moves:[ (row, column + 4) ] ~release:(row, column + 4));
  check string "coming back to the pressed cell does not undo the drag"
    (Printf.sprintf "copy main %d,%d-%d,%d" row column row column)
    (outcome ~press:(row, column) ~moves:[ (row, column + 4); (row, column) ]
       ~release:(row, column));
  check string "a release elsewhere with no motion reported is a drag"
    (Printf.sprintf "copy main %d,%d-%d,%d" row column (row + 1) column)
    (outcome ~press:(row, column) ~moves:[] ~release:(row + 1, column));
  check string "a drag from a row in no pane is nothing" "nothing"
    (outcome ~press:(strip_row, column) ~moves:[ (strip_row, column + 4) ]
       ~release:(strip_row, column + 4));
  check string "a click on a row in no pane is still a click"
    (Printf.sprintf "click %d,%d" strip_row column)
    (outcome ~press:(strip_row, column) ~moves:[] ~release:(strip_row, column));
  check string "a release with no press is nothing" "nothing"
    (show_outcome (Selection.release Selection.Idle ~row ~column));
  check bool "idle holds nothing" false (Selection.in_progress Selection.Idle);
  check bool "a press is held" true
    (Selection.in_progress (Selection.press layout ~row ~column))

let test_selection_is_held_inside_its_pane () =
  let row = first_body_row and column = main_left + 2 in
  let past = selection_of ~press:(row, column) ~moves:[ (row + 10, 500) ]
      ~release:(row + 10, 500) in
  check (pair int int) "dragged past the corner: the surface's last cell"
    (first_body_row + body_rows - 1, main_cols)
    (past.focus.row, past.focus.column);
  let into_roster = selection_of ~press:(row, column) ~moves:[ (strip_row, 1) ]
      ~release:(strip_row, 1) in
  check (pair int int) "dragged over the strip and the roster: the surface's first cell"
    (first_body_row, main_left)
    (into_roster.focus.row, into_roster.focus.column)

let span_triples spans =
  List.map
    (fun (span : Selection.span) -> (span.span_row, span.first_column, span.last_column))
    spans

let span_testable = triple int int int

let test_spans_run_in_reading_order () =
  let pane =
    match Selection.pane_at layout ~row:first_body_row ~column:main_left with
    | Some pane -> pane
    | None -> fail "the surface pane is missing"
  in
  let last_row = first_body_row + 2 in
  check (list span_testable) "dragged up and left, read top to bottom"
    [ (first_body_row, main_left + 3, main_cols)
    ; (first_body_row + 1, main_left, main_cols)
    ; (last_row, main_left, main_left + 6)
    ]
    (span_triples
       (Selection.spans
          { pane; anchor = point last_row (main_left + 6);
            focus = point first_body_row (main_left + 3) }));
  check (list span_testable) "one row, dragged left"
    [ (first_body_row, main_left + 1, main_left + 5) ]
    (span_triples
       (Selection.spans
          { pane; anchor = point first_body_row (main_left + 5);
            focus = point first_body_row (main_left + 1) }))

let test_text_is_one_pane_without_styles () =
  let selection =
    selection_of ~press:(first_body_row, main_left)
      ~moves:[ (first_body_row + 1, main_cols + activity_cols) ]
      ~release:(first_body_row + 1, main_cols + activity_cols)
  in
  check (option string) "the surface's text only, trailing blanks dropped"
    (Some "first line\nsecond line")
    (Selection.text selection frame_rows);
  let roster =
    selection_of ~press:(first_body_row, 1) ~moves:[ (first_body_row + 2, main_cols) ]
      ~release:(first_body_row + 2, main_cols)
  in
  check (option string) "the roster's text only"
    (Some "keeper-a\nkeeper-b\nkeeper-c")
    (Selection.text roster frame_rows);
  let blank =
    selection_of ~press:(first_body_row, main_cols - 2) ~moves:[ (first_body_row, main_cols) ]
      ~release:(first_body_row, main_cols)
  in
  check (option string) "only blanks copy nothing" None (Selection.text blank frame_rows)

(* Hangul takes two cells a character. A selection that starts on the right
   half of one and ends on the left half of another takes both whole. *)
let wide_rows =
  [ strip; joined ~roster:"keeper-a" ~main:"가나다 end" ~activity:"call 1" ]

let test_wide_characters_are_never_split () =
  let selection =
    selection_of ~press:(first_body_row, main_left + 1)
      ~moves:[ (first_body_row, main_left + 4) ]
      ~release:(first_body_row, main_left + 4)
  in
  check (option string) "both edge characters whole" (Some "가나다")
    (Selection.text selection wide_rows);
  let highlighted = Selection.highlight selection wide_rows in
  check (list string) "the highlight keeps every character"
    (List.map Masc_tui_theme.strip_sgr wide_rows)
    (List.map Masc_tui_theme.strip_sgr highlighted);
  check bool "the band opens on a whole character" true
    (contains (List.nth highlighted 1) (Masc_tui_theme.selection ^ "가나다"))

let test_highlight_marks_only_the_selection () =
  let selection =
    selection_of ~press:(first_body_row, main_left) ~moves:[ (first_body_row, main_left + 4) ]
      ~release:(first_body_row, main_left + 4)
  in
  let highlighted = Selection.highlight selection frame_rows in
  check (list string) "rows outside the selection are the frame's"
    [ List.nth frame_rows 0; List.nth frame_rows 2; List.nth frame_rows 3 ]
    [ List.nth highlighted 0; List.nth highlighted 2; List.nth highlighted 3 ];
  check string "the selected row keeps its text"
    (Masc_tui_theme.strip_sgr (List.nth frame_rows 1))
    (Masc_tui_theme.strip_sgr (List.nth highlighted 1));
  check bool "the selected cells are drawn reversed" true
    (contains (List.nth highlighted 1) (Masc_tui_theme.selection ^ "first"))

(* A row drawn shorter than the pane still shows the selection over the
   cells the terminal leaves blank. *)
let test_highlight_pads_a_short_row () =
  let short_rows = [ strip; "ab" ] in
  let layout =
    Selection.frame_layout ~first_row:first_body_row ~body_rows:1 ~main_cols
      ~activity_cols:0 ~roster:None
  in
  let selection =
    match
      Selection.release
        (Selection.drag (Selection.press layout ~row:first_body_row ~column:1)
           ~row:first_body_row ~column:5)
        ~row:first_body_row ~column:5
    with
    | Selection.Copy selection -> selection
    | (Selection.Click _ | Selection.Nothing) as other ->
        failf "expected a selection, got %s" (show_outcome other)
  in
  check string "blanks drawn up to the selection's end" "ab   "
    (Masc_tui_theme.strip_sgr (List.nth (Selection.highlight selection short_rows) 1));
  check (option string) "and copied as the text alone" (Some "ab")
    (Selection.text selection short_rows)

let () =
  run "tui_pane_selection"
    [ ( "panes",
        [ test_case "a press is placed by the recorded rectangles" `Quick
            test_pane_hit_uses_recorded_rectangles
        ; test_case "rows below the roster are in no left pane" `Quick
            test_rows_below_the_roster_are_in_no_left_pane
        ] )
    ; ( "gesture",
        [ test_case "a click and a drag are told apart" `Quick
            test_click_and_drag_are_told_apart
        ; test_case "a selection is held inside its pane" `Quick
            test_selection_is_held_inside_its_pane
        ; test_case "spans run in reading order" `Quick test_spans_run_in_reading_order
        ] )
    ; ( "text",
        [ test_case "one pane's text without styles" `Quick
            test_text_is_one_pane_without_styles
        ; test_case "wide characters are never split" `Quick
            test_wide_characters_are_never_split
        ] )
    ; ( "highlight",
        [ test_case "only the selection is marked" `Quick
            test_highlight_marks_only_the_selection
        ; test_case "a short row is padded" `Quick test_highlight_pads_a_short_row
        ] )
    ]
