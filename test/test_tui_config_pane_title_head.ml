(* The head of a Config pane's title row: the pane's name, and the reading it
   has to add beside it.

   The name is what the pane is called; the reading is a count, a warning, a
   mode. When the row runs short the reading gives way, and then the name goes
   whole. It is never drawn as a stub: "MASC Conf" and a mark says nothing the
   tab strip a row above does not already say with the marked Config entry,
   and it still spends the cells the rest of the row needs. *)

let cells text =
  Masc_tui_message_layout.display_width (Masc_tui_theme.strip_sgr text)

(* Measured off the gap the row actually draws, not written down beside it:
   a two spelled here and a three drawn there is how a test stops asking the
   question it was written for. *)
let gap_cells = cells Masc_tui_ansi.tab_strip_gap

let head ~room ~name ~reading =
  Masc_tui_render_prim.config_pane_title_head ~room ~name ~reading

let holds haystack needle =
  let n = String.length needle and h = String.length haystack in
  let rec walk index = index + n <= h && (String.sub haystack index n = needle || walk (index + 1)) in
  n = 0 || walk 0

let test_both_parts_fit () =
  let drawn = head ~room:40 ~name:" MASC Config" ~reading:"3 panes" in
  Alcotest.(check bool) "the name is there" true (holds drawn "MASC Config");
  Alcotest.(check bool) "and so is the reading" true (holds drawn "3 panes");
  let gap = Masc_tui_ansi.tab_strip_gap in
  let gap_bytes = String.length gap in
  Alcotest.(check bool) "and the head ends on the gap that holds the keys off"
    true
    (String.length drawn >= gap_bytes
     && String.equal (String.sub drawn (String.length drawn - gap_bytes) gap_bytes) gap)

let test_the_reading_gives_way_first () =
  let name = " MASC Config" in
  let room = cells name + gap_cells + 8 in
  let drawn = head ~room ~name ~reading:"a reading far too long for this row" in
  Alcotest.(check bool) "the name is drawn whole" true (holds drawn name);
  Alcotest.(check bool) "the reading is cut" false
    (holds drawn "far too long");
  Alcotest.(check int) "and the head spends exactly the room it was given" room
    (cells drawn)

let test_a_name_that_does_not_fit_is_not_drawn_at_all () =
  let name = " MASC Config" in
  (* One cell short of the name and the gap after it. *)
  let room = cells name + gap_cells - 1 in
  let drawn = head ~room ~name ~reading:"" in
  Alcotest.(check string) "nothing, rather than a stub of the name" "" drawn;
  Alcotest.(check bool) "so no mark stands in for it" false (holds drawn "\xe2\x80\xa6")

let test_the_name_survives_a_reading_it_cannot_hold () =
  let name = " MASC Themes" in
  let room = cells name + gap_cells in
  let drawn = head ~room ~name ~reading:"12 themes" in
  Alcotest.(check bool) "the name is whole" true (holds drawn name);
  Alcotest.(check bool) "the reading is gone rather than cut to nothing" false
    (holds drawn "12")

let () =
  Alcotest.run "masc tui config pane title head"
    [ ( "head"
      , [ Alcotest.test_case "both parts fit" `Quick test_both_parts_fit
        ; Alcotest.test_case "the reading gives way first" `Quick
            test_the_reading_gives_way_first
        ; Alcotest.test_case "a name that does not fit is not drawn" `Quick
            test_a_name_that_does_not_fit_is_not_drawn_at_all
        ; Alcotest.test_case "the name survives a reading it cannot hold" `Quick
            test_the_name_survives_a_reading_it_cannot_hold
        ] )
    ]
