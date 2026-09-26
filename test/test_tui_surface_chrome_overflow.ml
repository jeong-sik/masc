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

(* The strip is the frame's first line and the body's rows follow it, so the
   footer -- the body's last row -- is line [surface_body_rows]. *)
let footer_line state = Masc_tui_types.surface_body_rows state ~terminal_rows

let test_the_footer_stays_above_the_composer () =
  let state = fresh () in
  let budget = surface_chrome_budget state ~terminal_rows in
  List.iter
    (fun (overflow, name) ->
      List.iter
        (fun count ->
          let lines, _ = draw ~overflow ~count state in
          Alcotest.(check (option int))
            (Printf.sprintf "%s, %d rows: the footer is the body's last row"
               name count)
            (Some (footer_line state))
            (index_of lines "zz:probe"))
        [ 0; 1; budget; budget + 1; budget * 3 ])
    [ (Fits, "fits")
    ; (Paged_by_cursor, "paged")
    ; (Scrolled { scroll = 0; report = report_into (ref None) }, "scrolled")
    ]

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

let () =
  Alcotest.run "tui_surface_chrome_overflow"
    [ ( "surface chrome overflow"
      , [ Alcotest.test_case "the footer stays above the composer" `Quick
            test_the_footer_stays_above_the_composer
        ; Alcotest.test_case "a cut body says what it hides" `Quick
            test_a_cut_body_says_what_it_hides
        ; Alcotest.test_case "the frame windows a scrolled body" `Quick
            test_the_frame_windows_a_scrolled_body
        ] )
    ]
