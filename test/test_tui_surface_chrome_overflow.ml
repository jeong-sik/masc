(* The shared surface frame says what it does with rows past its budget.

   The contract used to drop the rows a body pushed past its budget, and the
   clamp was an optional argument that cost nothing to leave out: a body that
   fitted, one the keypress windowed and one losing its tail read the same at
   the call (#35716). Each surface now declares an [overflow], and these are
   what the frame draws for it: the footer on the row above the composer at
   every body length, a cut body that says how much the screen could not hold,
   and a scrolled body whose window, position row and clamp come from the
   frame rather than from the body. *)

open Masc_tui_render_prim

let terminal_rows = 30
let cols = 100
let hints = "zz:probe  Esc:close"

let fresh () =
  Masc_tui_types.create_state ~workspace:"test" ~port:8935
    ~refresh_interval:2.0 ()

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

let draw ?(frame = Chrome_screen) ~overflow ~count state =
  let drawn, clamped =
    surface_chrome ~overflow ~frame state ~terminal_rows ~cols
      ~surface_key:"surface-chrome-overflow" ~title:"probe" ~hints
      ~body:(fun ~budget:_ c ->
        List.iter (fun index -> c.push (row_text index)) (List.init count Fun.id))
  in
  (drawn.Masc_tui_frame_presenter.lines, clamped)

let report_into reported v =
  reported := Some v;
  Masc_tui_types.Context_inspector_scroll v

let test_a_cut_body_says_what_it_hides () =
  let state = fresh () in
  let budget = surface_chrome_budget state ~terminal_rows in
  let count = budget + 7 in
  let lines, clamped = draw ~overflow:Fits ~count state in
  Alcotest.(check bool) "the head is drawn" true (shows lines (row_text 0));
  Alcotest.(check bool) "the rows before the note are drawn" true
    (shows lines (row_text (budget - 2)));
  Alcotest.(check bool) "the note takes the budget's last row" false
    (shows lines (row_text (budget - 1)));
  Alcotest.(check bool) "the note counts every row it hides" true
    (shows lines (Printf.sprintf "+%d rows not shown" (count - (budget - 1))));
  Alcotest.(check bool) "a cut body clamps nothing" true
    (Option.is_none clamped);
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
  Alcotest.(check bool) "the position row names the window" true
    (shows lines
       (Printf.sprintf "[lines %d-%d/%d]" (count - height + 1) count count));
  let lines, _ =
    draw ~overflow:(Scrolled { scroll = 5; report = report_into reported })
      ~count:3 state
  in
  Alcotest.(check (option int)) "a short body is held at its top" (Some 0)
    !reported;
  Alcotest.(check bool) "and draws no position row" false
    (shows lines "[lines ")

(* Where a body row's content lands and how much of it the frame keeps, read
   from the frame's own constants. The margin is one number: a full-screen
   surface leaves it blank and an overlay draws its border in it, and on both
   the content starts at the same column, keeps the inner width whole, and is
   where a picture placed over the body starts. *)
let test_body_rows_follow_the_frame_margin () =
  let state = fresh () in
  let inner = Masc_tui_frame.inner_width ~cols in
  Alcotest.(check int) "the content gets what the two margins leave"
    (cols - (2 * Masc_tui_frame.margin_cells)) inner;
  Alcotest.(check int) "the content starts after the left margin"
    Masc_tui_frame.margin_cells Masc_tui_frame.content_column;
  Alcotest.(check int) "the outer width gives the inner width back" cols
    (Masc_tui_frame.outer_width ~inner);
  let marker = "margin-probe" in
  let full = marker ^ String.make (inner - String.length marker) 'x' in
  let cells = Masc_tui_message_layout.display_width in
  let byte_index_of line needle =
    let n = String.length needle and m = String.length line in
    let rec at i =
      if i + n > m then None
      else if String.sub line i n = needle then Some i
      else at (i + 1)
    in
    at 0
  in
  List.iter
    (fun (label, frame) ->
      let origin = ref None in
      let drawn, _ =
        surface_chrome ~overflow:Fits ~frame state ~terminal_rows ~cols
          ~surface_key:"surface-chrome-margin" ~title:"probe" ~hints
          ~body:(fun ~budget:_ c ->
            origin := Some (snd (c.next_origin ()));
            c.push full)
      in
      let rows =
        List.map Masc_tui_theme.strip_sgr
          drawn.Masc_tui_frame_presenter.lines
      in
      match
        List.find_map
          (fun row ->
            Option.map (fun index -> (row, index)) (byte_index_of row marker))
          rows
      with
      | None -> Alcotest.failf "%s: the probe row is not drawn" label
      | Some (row, index) ->
          Alcotest.(check int) (label ^ ": content starts at the content column")
            Masc_tui_frame.content_column (cells (String.sub row 0 index));
          Alcotest.(check bool) (label ^ ": a row of the inner width is drawn whole")
            true (contains row full);
          Alcotest.(check int) (label ^ ": the row spans the terminal") cols
            (cells row);
          Alcotest.(check (option int))
            (label ^ ": a picture over the body starts at the content column")
            (Some Masc_tui_frame.content_column) !origin)
    [ ("screen", Chrome_screen); ("overlay", Chrome_overlay) ]

let () =
  Alcotest.run "tui_surface_chrome_overflow"
    [ ( "surface chrome overflow"
      , [ Alcotest.test_case "a cut body says what it hides" `Quick
            test_a_cut_body_says_what_it_hides
        ; Alcotest.test_case "the frame windows a scrolled body" `Quick
            test_the_frame_windows_a_scrolled_body
        ; Alcotest.test_case "body rows follow the frame margin" `Quick
            test_body_rows_follow_the_frame_margin
        ;] )
    ]
