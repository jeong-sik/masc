open Alcotest
module Mark = Masc_tui_planning_proof_mark
module Decode = Masc.Tui_decode

(* Every verdict the wire can carry. Written out rather than derived, because a
   state added to [goal_proof] should stop this list being complete and say so
   in the failure below -- the module's own matches already refuse to compile
   without a mark and a word for it. *)
let every_verdict =
  [ Decode.Proof_idle
  ; Decode.Proof_pending
  ; Decode.Proof_proven None
  ; Decode.Proof_refuted None
  ; Decode.Proof_stale None
  ; Decode.Proof_unreadable None
  ]

let test_the_legend_explains_every_mark_a_row_can_draw () =
  check (list (pair string string))
    "every verdict at once asks for the whole legend" Mark.legend
    (Mark.legend_for every_verdict);
  List.iter
    (fun verdict ->
      let mark = Mark.glyph verdict in
      if not (String.equal mark " ") then
        check bool ("the legend names " ^ mark) true
          (List.exists (fun (m, _) -> String.equal m mark) Mark.legend))
    every_verdict

let test_the_legend_says_only_what_the_list_draws () =
  check (list (pair string string)) "a list of waiting goals gets one row"
    [ ("\xe2\x80\xa6", "waiting") ]
    (Mark.legend_for
       [ Decode.Proof_pending; Decode.Proof_pending; Decode.Proof_idle ]);
  check int "no goals, no legend" 0 (List.length (Mark.legend_for []));
  check int "goals nobody asked about, no legend" 0
    (List.length (Mark.legend_for [ Decode.Proof_idle; Decode.Proof_idle ]))

let test_the_legend_keeps_its_own_order () =
  check (list string) "the order is the journey, not the row order"
    [ "\xe2\x9c\x93"; "~" ]
    (List.map fst
       (Mark.legend_for [ Decode.Proof_stale None; Decode.Proof_proven None ]))

(* The mark the column draws and the mark the legend explains come from one
   function, so they cannot disagree. This is the assertion that would have
   caught the missing entry: "criterion changed" had no word for its glyph
   while the column drew it. *)
let test_the_column_and_the_legend_read_the_same_glyph () =
  List.iter
    (fun verdict ->
      match Mark.legend_for [ verdict ] with
      | [] ->
          check string "a verdict with no legend row draws a blank" " "
            (Mark.glyph verdict)
      | [ (mark, _) ] ->
          check string ("the legend's glyph is the column's for " ^ mark)
            (Mark.glyph verdict) mark
      | rows -> failf "one verdict asked for %d legend rows" (List.length rows))
    every_verdict

(* Exercise the actual frame writer: measuring the entries alone misses its
   truncation, whose '~' is indistinguishable from the stale verdict's mark. *)
let render_legend ~cols ~max_rows proofs =
  let rows =
    Mark.legend_rows ~max_cells:(Masc_tui_ansi.framed_inner_width cols)
      ~max_rows proofs
  in
  let buf = Buffer.create 256 in
  List.iter
    (Masc_tui_ansi.box_line_styled buf cols ~style:Masc_tui_ansi.Ansi.dim)
    rows;
  String.split_on_char '\n' (Buffer.contents buf)
  |> List.filter (fun row -> not (String.equal row ""))

let plain_rows rows = List.map Masc_tui_theme.strip_sgr rows

let words text =
  String.split_on_char ' ' text
  |> List.filter (fun word -> not (String.equal word ""))

let full_legend =
  "JUDGE … waiting ✓ proven ✗ refused, back in executing ~ criterion changed ! unreadable"

let check_frame_width cols rows =
  List.iter
    (fun row ->
      check int "the styled frame spans exactly the terminal width" cols
        (Masc_tui_message_layout.display_width row))
    rows

let test_full_legend_renders_at_eighty_columns () =
  let rows = render_legend ~cols:80 ~max_rows:2 every_verdict in
  check int "all five explanations use two rows" 2 (List.length rows);
  check_frame_width 80 rows;
  check (list string) "every complete explanation survives the frame writer"
    (words full_legend) (words (String.concat " " (plain_rows rows)))

let test_legend_preserves_height_and_complete_text () =
  List.iter
    (fun cols ->
      (* Even one character per row needs no more than this many rows. *)
      let rows =
        render_legend ~cols ~max_rows:(String.length full_legend) every_verdict
      in
      let needed = List.length rows in
      check bool "the full legend is present" true (needed > 0);
      check_frame_width cols rows;
      let without_spaces text = String.concat "" (words text) in
      check string "wrapping loses no text and adds no stale/truncation mark"
        (without_spaces full_legend)
        (without_spaces (String.concat "" (plain_rows rows)));
      check (list string) "exact remaining height fits all legend rows" rows
        (render_legend ~cols ~max_rows:needed every_verdict);
      check (list string) "one less row preserves the goal/footer reservation" []
        (render_legend ~cols ~max_rows:(needed - 1) every_verdict))
    [ 20; 40; 80; 120 ];
  check (list string) "negative remaining height draws no legend" []
    (render_legend ~cols:80 ~max_rows:(-1) every_verdict);
  check (list string) "idle goals need no legend rows" []
    (render_legend ~cols:80 ~max_rows:2 [ Decode.Proof_idle ])

let test_legend_uses_cells_not_utf8_bytes () =
  (* The narrowest frame the one-row legend fits in: "  JUDGE  " is 9 cells,
     the mark and its space 2, "waiting" 7, and the frame's border and padding
     4 more. Counted in bytes instead the mark is 3 and the text needs 11 of
     the 9 it has, so the row wraps and a one-row budget draws nothing. *)
  let rows = render_legend ~cols:22 ~max_rows:1 [ Decode.Proof_pending ] in
  check int "the UTF-8 mark fits in its one cell" 1 (List.length rows);
  check_frame_width 22 rows;
  check (list string) "the narrow rendered legend is complete"
    [ "JUDGE"; "…"; "waiting" ]
    (words (String.concat " " (plain_rows rows)))

let () =
  run "tui planning proof mark"
    [ ( "judge legend"
      , [ test_case "the legend explains every mark a row can draw" `Quick
            test_the_legend_explains_every_mark_a_row_can_draw
        ; test_case "the legend says only what the list draws" `Quick
            test_the_legend_says_only_what_the_list_draws
        ; test_case "the legend keeps its own order" `Quick
            test_the_legend_keeps_its_own_order
        ; test_case "the column and the legend read the same glyph" `Quick
            test_the_column_and_the_legend_read_the_same_glyph
        ; test_case "the full legend renders at eighty columns" `Quick
            test_full_legend_renders_at_eighty_columns
        ; test_case "height preserves whole explanations and reserved rows" `Quick
            test_legend_preserves_height_and_complete_text
        ; test_case "the legend uses cells rather than UTF-8 bytes" `Quick
            test_legend_uses_cells_not_utf8_bytes
        ] )
    ]
