(* The shared surface frame says what it does with rows past its budget.

   The contract used to drop the rows a body pushed past its budget, and the
   clamp was an optional argument that cost nothing to leave out: a body that
   fitted, one the keypress windowed and one losing its tail read the same at
   the call (#35716). Each surface now declares an [overflow], and these are
   what the frame draws for it: the footer on the row above the composer at
   every body length, a cut body that says how much the screen could not hold,
   and a scrolled body whose window, position and clamp come from the frame
   rather than from the body. The position is read as the value the title row
   was handed, never as the text drawn (RFC tui-one-screen-grammar, section
   10). *)

open Masc_tui_render_prim

let terminal_rows = 30
let cols = 100
let hints = "zz:probe  Esc:close"

(* The cut note's words are the English screen's; the language a fresh
   state starts in is Korean. *)
let fresh () =
  let state = Masc_tui_types.create_state ~workspace:"test" ~port:8935 () in
  state.Masc_tui_types.ui_language <- Masc_tui_types.Lang_en;
  state

let row_text index = Printf.sprintf "row-%03d" index

let contains line needle =
  let n = String.length needle and m = String.length line in
  let rec at i = i + n <= m && (String.sub line i n = needle || at (i + 1)) in
  at 0

let index_of lines needle =
  let rec find i = function
    | [] -> None
    | line :: rest -> if contains line needle then Some i else find (i + 1) rest
  in
  find 0 lines

let shows lines needle = Option.is_some (index_of lines needle)

(* The position the contract decides for the last body drawn, read as the
   value [surface_chrome_position] returns for that same body. *)
let drawn_position = ref None

let draw_body ~body ~overflow state =
  drawn_position := surface_chrome_position ~overflow state ~terminal_rows ~body;
  surface_chrome ~overflow state ~terminal_rows ~cols
    ~surface_key:"surface-chrome-overflow" ~title:"probe" ~hints ~body

let draw ?(frame = Chrome_screen) ?hand ~overflow ~count state =
  let body ~budget c =
    List.iter (fun index -> c.push (row_text index)) (List.init count Fun.id);
    Option.iter (fun hand -> Option.iter c.position (hand ~budget)) hand
  in
  drawn_position := surface_chrome_position ~frame ~overflow state ~terminal_rows ~body;
  let drawn, clamped =
    surface_chrome ~overflow ~frame state ~terminal_rows ~cols
      ~surface_key:"surface-chrome-overflow" ~title:"probe" ~hints ~body
  in
  (drawn.Masc_tui_frame_presenter.lines, clamped)

let window_numbers () =
  match !drawn_position with
  | Some (Masc_tui_value.Position.Window { first; last; total }) ->
      Some (first, last, total)
  | Some (Masc_tui_value.Position.Row _ | Masc_tui_value.Position.Partial _)
  | None -> None

let report_into reported v =
  reported := Some v;
  Masc_tui_types.Context_inspector_scroll v

let test_a_cut_body_says_what_it_hides () =
  let state = fresh () in
  let budget =
    surface_chrome_budget ~frame:Chrome_screen ~has_recovery:false state
      ~terminal_rows
  in
  let count = budget + 7 in
  let lines, clamped = draw ~overflow:Fits ~count state in
  Alcotest.(check bool) "the head is drawn" true (shows lines (row_text 0));
  Alcotest.(check bool) "the rows before the note are drawn" true
    (shows lines (row_text (budget - 2)));
  Alcotest.(check bool) "the note takes the budget's last row" false
    (shows lines (row_text (budget - 1)));
  Alcotest.(check bool) "the note counts every row it hides" true
    (shows lines (Printf.sprintf "%d more rows" (count - (budget - 1))));
  Alcotest.(check bool) "a cut body clamps nothing" true
    (Option.is_none clamped);
  Alcotest.(check bool) "a cut body that hands no position has none" true
    (Option.is_none !drawn_position);
  let lines, _ = draw ~overflow:Fits ~count:budget state in
  Alcotest.(check bool) "a body that fits says nothing" false
    (shows lines "not shown")

let test_the_frame_windows_a_scrolled_body () =
  let state = fresh () in
  let count = 200 in
  let height = surface_window_height state ~terminal_rows ~count in
  let reported = ref None in
  let lines, clamped =
    draw ~frame:Chrome_overlay
      ~overflow:
        (Scrolled
           { scroll = Masc_tui_types.clamped_scroll_end
           ; report = report_into reported })
      ~count state
  in
  Alcotest.(check (option int)) "End is held at the last full window"
    (Some (count - height)) !reported;
  Alcotest.(check bool) "the clamp travels with the frame" true
    (match clamped with
     | Some (Masc_tui_types.Context_inspector_scroll v) -> v = count - height
     | Some _ | None -> false);
  Alcotest.(check bool) "the last row is on screen" true
    (shows lines (row_text (count - 1)));
  Alcotest.(check bool) "the row above the window is not" false
    (shows lines (row_text (count - height - 1)));
  Alcotest.(check bool) "every row of the budget shows content" true
    (shows lines (row_text (count - height)));
  Alcotest.(check (option (triple int int int))) "the title row is handed the window"
    (Some (count - height + 1, count, count)) (window_numbers ());
  let _, _ =
    draw ~overflow:(Scrolled { scroll = 5; report = report_into reported })
      ~count:3 state
  in
  Alcotest.(check (option int)) "a short body is held at its top" (Some 0)
    !reported;
  Alcotest.(check bool) "and hands no position" true
    (Option.is_none !drawn_position)

(* A body the keypress windows knows where its reader is and hands it; the
   title row carries what it was handed, and a body that shows every row
   hands nothing. *)
let test_a_paged_body_hands_its_position () =
  let state = fresh () in
  let budget =
    surface_chrome_budget ~frame:Chrome_screen ~has_recovery:false state
      ~terminal_rows
  in
  let total = budget * 3 in
  let hand ~budget = Masc_tui_value.Position.window ~first:budget ~shown:budget ~total in
  let _ = draw ~overflow:Paged_by_cursor ~hand ~count:budget state in
  Alcotest.(check (option (triple int int int))) "the handed window is the frame's"
    (Some (budget + 1, budget * 2, total)) (window_numbers ());
  let fits ~budget = Masc_tui_value.Position.window ~first:0 ~shown:budget ~total:budget in
  let _ = draw ~overflow:Paged_by_cursor ~hand:fits ~count:budget state in
  Alcotest.(check bool) "a body that shows every row hands none" true
    (Option.is_none !drawn_position)

(* The contract owns a scrolled body's window, so a position the body hands
   as well gives way to it; a paged body that hands twice is drawn with the
   last one it handed (RFC tui-one-screen-grammar, section 2). *)
let test_the_contract_decides_which_position_is_drawn () =
  let state = fresh () in
  let budget =
    surface_chrome_budget ~frame:Chrome_screen ~has_recovery:false state
      ~terminal_rows
  in
  let count = budget * 4 in
  let reported = ref None in
  let _ =
    draw
      ~hand:(fun ~budget:_ -> Some (Masc_tui_value.Position.row ~selected:(Some 2) ~total:9))
      ~overflow:(Scrolled { scroll = 0; report = report_into reported })
      ~count state
  in
  Alcotest.(check (option (triple int int int)))
    "a scrolled body is drawn with the contract's window"
    (Some
       ( 1
       , surface_window_height ~frame:Chrome_screen ~has_recovery:false state
           ~terminal_rows ~count
       , count ))
    (window_numbers ());
  let _ =
    draw_body ~overflow:Paged_by_cursor state
      ~body:(fun ~budget c ->
        c.position (Masc_tui_value.Position.row ~selected:(Some 0) ~total:3);
        Option.iter c.position
          (Masc_tui_value.Position.window ~first:3 ~shown:budget ~total:(budget * 2)))
  in
  Alcotest.(check (option (triple int int int))) "the last position handed is drawn"
    (Some (4, budget + 3, budget * 2)) (window_numbers ())

let test_empty_zone4_reclaims_rows_on_screen () =
  let state = fresh () in
  let overlay_budget = surface_chrome_budget ~frame:Chrome_overlay state ~terminal_rows in
  let screen_budget = surface_chrome_budget ~frame:Chrome_screen ~has_recovery:false state ~terminal_rows in
  let screen_with_recovery = surface_chrome_budget ~frame:Chrome_screen ~has_recovery:true state ~terminal_rows in
  Alcotest.(check int) "Chrome_screen without recovery reclaims 2 rows over overlay"
    (overlay_budget + 2) screen_budget;
  Alcotest.(check int) "Chrome_screen with recovery reclaims 1 row over overlay"
    (overlay_budget + 1) screen_with_recovery

let () =
  Alcotest.run "tui_surface_chrome_overflow"
    [ ( "surface chrome overflow"
      , [ Alcotest.test_case "a cut body says what it hides" `Quick
            test_a_cut_body_says_what_it_hides
        ; Alcotest.test_case "the frame windows a scrolled body" `Quick
            test_the_frame_windows_a_scrolled_body
        ; Alcotest.test_case "a paged body hands its position" `Quick
            test_a_paged_body_hands_its_position
        ; Alcotest.test_case "the contract decides which position is drawn" `Quick
            test_the_contract_decides_which_position_is_drawn
        ; Alcotest.test_case "empty zone 4 reclaims rows on screen" `Quick
            test_empty_zone4_reclaims_rows_on_screen
        ] )
    ]
