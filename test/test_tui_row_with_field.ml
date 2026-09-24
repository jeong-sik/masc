(* A framed row is fitted to [Masc_tui_ansi.framed_inner_width] before it is
   drawn, and [Masc_tui_message_layout.fit_width] pads as well as cuts. So a
   row that fitted one of its own fields to a hand-counted width handed the
   frame a row wider than the frame, and the frame cut it and drew the cut
   mark over the padding the field had just added.

   Measured on the live server at 120 columns: the Config params pane drew its
   contract row as "int \xc2\xb7 min 1 \xc2\xb7 Heartbeat ..." followed by
   eighty-one blank cells and a mark, and all eight rows of the presets list
   ended the same way. [row_with_field] measures the field from the lead and
   the tail instead. *)

let cells text =
  Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr text)

let cut_mark = Masc_tui_message_layout.cut_mark

let ends_with ~suffix text =
  let n = String.length suffix and h = String.length text in
  n <= h && String.equal (String.sub text (h - n) n) suffix

(* The presets pane's name prompt: a label, the name being typed, and the two
   keys that end it. The keys sat behind a field padded to a hand count, so
   the frame cut them off and no width drew them. *)
let save_lead = "  \xec\x9d\xb4\xeb\xa6\x84: "
let save_tail = "  Enter:\xec\xa0\x80\xec\x9e\xa5  Esc:\xec\xb7\xa8\xec\x86\x8c"

let test_a_row_keeps_its_tail () =
  List.iter
    (fun cols ->
      let drawn =
        Masc_tui_ansi.row_with_field ~cols ~lead:save_lead ~field:"nightly"
          ~tail:save_tail
      in
      Alcotest.(check int)
        (Printf.sprintf "%d columns: the row is the frame's width" cols)
        (Masc_tui_ansi.framed_inner_width cols)
        (cells drawn);
      Alcotest.(check bool)
        (Printf.sprintf "%d columns: the keys are still drawn" cols)
        true
        (ends_with ~suffix:save_tail (Masc_tui_theme.strip_sgr drawn)))
    [ 80; 100; 120; 160 ]

(* The params pane's edit row: a label and the value being typed, nothing
   behind it. *)
let test_a_row_that_fits_carries_no_mark () =
  List.iter
    (fun lead ->
      let drawn =
        Masc_tui_ansi.row_with_field ~cols:120 ~lead ~field:"600" ~tail:""
      in
      Alcotest.(check int) "the row is the frame's width"
        (Masc_tui_ansi.framed_inner_width 120)
        (cells drawn);
      Alcotest.(check bool) "nothing was dropped, so nothing says so" false
        (ends_with ~suffix:cut_mark drawn))
    [ "  JSON> "; "  value> "; "  choice> " ]

(* A field that really is too wide says so, and says it in its own cells: the
   tail behind it is what the row would have lost to a cut of the whole row. *)
let test_a_field_that_does_not_fit_carries_the_mark () =
  let drawn =
    Masc_tui_ansi.row_with_field ~cols:60 ~lead:save_lead
      ~field:(String.make 200 'n') ~tail:save_tail
  in
  let plain = Masc_tui_theme.strip_sgr drawn in
  Alcotest.(check int) "the row is still the frame's width"
    (Masc_tui_ansi.framed_inner_width 60)
    (cells drawn);
  Alcotest.(check bool) "the keys are still drawn" true
    (ends_with ~suffix:save_tail plain);
  Alcotest.(check bool) "and the field says it was cut" true
    (ends_with ~suffix:(cut_mark ^ save_tail) plain)

(* When the lead and the tail leave nothing, the field keeps one cell and the
   row runs past the frame. The frame cuts it there, and that mark is the row
   saying something really was dropped. *)
let test_a_full_row_leaves_the_field_one_cell () =
  let cols = 20 in
  let drawn =
    Masc_tui_ansi.row_with_field ~cols ~lead:save_lead ~field:"nightly"
      ~tail:save_tail
  in
  Alcotest.(check int) "lead, one cell, tail"
    (cells save_lead + 1 + cells save_tail)
    (cells drawn);
  Alcotest.(check bool) "which is wider than the frame" true
    (cells drawn > Masc_tui_ansi.framed_inner_width cols)

(* The two panes measured above lay their rows out through the helper. The
   params pane has no hand-counted fit left at all. *)
let render = "bin/masc_tui_render.ml"

let calls ~binding ~callee =
  Ast_grep.count_calls_in_value_binding ~module_path:render
    ~binding_name:binding ~callee

let test_the_panes_measured_here_lay_out_through_the_helper () =
  Alcotest.(check int) "params: the edit row" 1
    (calls ~binding:"render_runtime_params" ~callee:"row_with_field");
  Alcotest.(check int) "params: and no hand count beside it" 0
    (calls ~binding:"render_runtime_params" ~callee:"fit_width");
  Alcotest.(check int) "presets: the list rows and the name prompt" 2
    (calls ~binding:"render_presets" ~callee:"row_with_field")

let () =
  Alcotest.run "tui_row_with_field"
    [ ( "a row of lead, field and tail"
      , [ Alcotest.test_case "a row keeps its tail" `Quick
            test_a_row_keeps_its_tail
        ; Alcotest.test_case "a row that fits carries no mark" `Quick
            test_a_row_that_fits_carries_no_mark
        ; Alcotest.test_case "a field that does not fit carries the mark"
            `Quick test_a_field_that_does_not_fit_carries_the_mark
        ; Alcotest.test_case "a full row leaves the field one cell" `Quick
            test_a_full_row_leaves_the_field_one_cell
        ; Alcotest.test_case "the panes lay out through the helper" `Quick
            test_the_panes_measured_here_lay_out_through_the_helper
        ] )
    ]
