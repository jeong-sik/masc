(* Where a press lands, read back from the rows the terminal is sent.

   The renderer never says which column it drew a tab at; it wraps the tab's
   text and lets the rows be joined, styled and cut as they always were.
   These cases are the ways a row changes on its way out -- styles, wide
   characters, a cut -- and in each the press has to land on the cells the
   reader sees the text in. *)

let check = Alcotest.check

type target = Tab of string

let target = Alcotest.testable (fun ppf (Tab name) -> Format.fprintf ppf "Tab %s" name) ( = )

let found = Alcotest.option target

let extract registry lines = Masc_tui_hit.extract registry lines

let introducer = "\027[="

let has_introducer line =
  let length = String.length introducer in
  let rec scan index =
    index + length <= String.length line
    && (String.equal (String.sub line index length) introducer || scan (index + 1))
  in
  scan 0

let test_a_marked_word_is_found_where_it_was_drawn () =
  let registry = Masc_tui_hit.registry () in
  let line =
    " " ^ Masc_tui_hit.mark registry (Tab "overview") "Overview" ^ "  "
    ^ Masc_tui_hit.mark registry (Tab "board") "Board"
  in
  let lines, zones = extract registry [ line ] in
  check Alcotest.(list string) "the terminal gets the text without marks"
    [ " Overview  Board" ] lines;
  check found "the first cell of Overview" (Some (Tab "overview"))
    (Masc_tui_hit.target_at zones ~row:1 ~column:2);
  check found "the last cell of Overview" (Some (Tab "overview"))
    (Masc_tui_hit.target_at zones ~row:1 ~column:9);
  check found "the gap between the tabs" None
    (Masc_tui_hit.target_at zones ~row:1 ~column:10);
  check found "Board" (Some (Tab "board"))
    (Masc_tui_hit.target_at zones ~row:1 ~column:12);
  check found "past Board" None (Masc_tui_hit.target_at zones ~row:1 ~column:17);
  check found "another row" None (Masc_tui_hit.target_at zones ~row:2 ~column:12)

(* A style costs no cells and a Hangul syllable costs two. Counting bytes
   would put the mark eleven columns right of where it is drawn. *)
let test_styles_and_wide_characters_move_a_mark_by_cells () =
  let registry = Masc_tui_hit.registry () in
  let line =
    "\027[1m\xed\x95\x9c\xea\xb8\x80\027[0m " ^ Masc_tui_hit.mark registry (Tab "x") "x"
  in
  let lines, zones = extract registry [ line ] in
  check Alcotest.(list string) "only the marks are removed"
    [ "\027[1m\xed\x95\x9c\xea\xb8\x80\027[0m x" ] lines;
  check found "after two wide syllables and a space" (Some (Tab "x"))
    (Masc_tui_hit.target_at zones ~row:1 ~column:6);
  check found "the space before it" None
    (Masc_tui_hit.target_at zones ~row:1 ~column:5)

(* The frame cuts a row that is too wide and ends it with a cut mark. The
   close mark goes with the cut text, so what is left of the tab runs to the
   end of the row -- the reader sees part of the name and the mark, and a
   press on either is a press on that tab. *)
let test_a_cut_row_keeps_what_is_left_of_the_mark () =
  let registry = Masc_tui_hit.registry () in
  let row = "abc " ^ Masc_tui_hit.mark registry (Tab "cut") "tabname" in
  let cut = Masc_tui_message_layout.fit_width row 7 in
  let lines, zones = extract registry [ cut ] in
  (match lines with
   | [ line ] ->
       check Alcotest.bool "no mark reaches the terminal" false (has_introducer line);
       check Alcotest.int "the row is as wide as the cut made it" 7
         (Masc_tui_message_layout.display_width line)
   | _ -> Alcotest.fail "one row in, one row out");
  check found "before the tab" None (Masc_tui_hit.target_at zones ~row:1 ~column:4);
  check found "what is left of the name" (Some (Tab "cut"))
    (Masc_tui_hit.target_at zones ~row:1 ~column:5);
  check found "the cut mark" (Some (Tab "cut"))
    (Masc_tui_hit.target_at zones ~row:1 ~column:7)

let test_an_escape_that_is_not_a_mark_is_kept () =
  let registry = Masc_tui_hit.registry () in
  let line = "\027[31mred\027[0m \027[=5z" in
  let lines, zones = extract registry [ line ] in
  check Alcotest.(list string) "unchanged" [ line ] lines;
  check Alcotest.int "no zones" 0 (List.length (Masc_tui_hit.to_list zones))

(* Marks do not nest. A renderer that wrapped a strip and then its entries
   would otherwise make the strip answer for the gaps between them. *)
let test_a_mark_opened_inside_another_closes_it () =
  let registry = Masc_tui_hit.registry () in
  let line =
    Masc_tui_hit.mark registry (Tab "outer")
      ("x" ^ Masc_tui_hit.mark registry (Tab "inner") "y" ^ "z")
  in
  let lines, zones = extract registry [ line ] in
  check Alcotest.(list string) "text" [ "xyz" ] lines;
  check found "x" (Some (Tab "outer")) (Masc_tui_hit.target_at zones ~row:1 ~column:1);
  check found "y" (Some (Tab "inner")) (Masc_tui_hit.target_at zones ~row:1 ~column:2);
  check found "z" None (Masc_tui_hit.target_at zones ~row:1 ~column:3)

(* Numbers name the targets of one frame. After a reset the old numbers name
   nothing: their marks are still removed, and they answer no press. *)
let test_a_reset_registry_answers_no_old_mark () =
  let registry = Masc_tui_hit.registry () in
  let line = Masc_tui_hit.mark registry (Tab "stale") "old" in
  Masc_tui_hit.reset registry;
  let lines, zones = extract registry [ line ] in
  check Alcotest.(list string) "the marks are removed" [ "old" ] lines;
  check found "the old target is gone" None
    (Masc_tui_hit.target_at zones ~row:1 ~column:1)

let test_rows_count_from_one () =
  let registry = Masc_tui_hit.registry () in
  let lines =
    [ "strip"; "  " ^ Masc_tui_hit.mark registry (Tab "second") "here" ]
  in
  let _, zones = extract registry lines in
  check
    Alcotest.(list (pair (pair int int) int))
    "row two, cells three to six"
    [ ((2, 3), 6) ]
    (List.map (fun (row, first, last, _) -> ((row, first), last))
       (Masc_tui_hit.to_list zones))

let test_an_empty_mark_answers_nothing () =
  let registry = Masc_tui_hit.registry () in
  let lines, zones = extract registry [ "a" ^ Masc_tui_hit.mark registry (Tab "empty") "" ^ "b" ] in
  check Alcotest.(list string) "text" [ "ab" ] lines;
  check Alcotest.int "no zones" 0 (List.length (Masc_tui_hit.to_list zones))

(* A press target and a scroll region can wrap the same rows. Each registry
   reads its own marks and leaves the other's, and the other's marks cost no
   cells, so neither moves the other's columns. *)
let test_two_registries_read_only_their_own_marks () =
  let presses = Masc_tui_hit.registry () in
  let regions = Masc_tui_hit.registry () in
  let line =
    Masc_tui_hit.mark regions (Tab "region")
      ("ab" ^ Masc_tui_hit.mark presses (Tab "press") "cd" ^ "ef")
  in
  let after_presses, press_zones = extract presses [ line ] in
  check found "the press is where it was drawn" (Some (Tab "press"))
    (Masc_tui_hit.target_at press_zones ~row:1 ~column:3);
  (match after_presses with
   | [ remaining ] ->
       check Alcotest.bool "the region marks are still there" true
         (has_introducer remaining)
   | _ -> Alcotest.fail "one row in, one row out");
  let clean, region_zones = extract regions after_presses in
  check Alcotest.(list string) "both sets gone" [ "abcdef" ] clean;
  check found "the region spans the row" (Some (Tab "region"))
    (Masc_tui_hit.target_at region_zones ~row:1 ~column:6);
  check found "the pressed cells sit inside the region" (Some (Tab "region"))
    (Masc_tui_hit.target_at region_zones ~row:1 ~column:3)

let () =
  Alcotest.run "tui_hit"
    [ ( "zones",
        [ Alcotest.test_case "a marked word is found where it was drawn" `Quick
            test_a_marked_word_is_found_where_it_was_drawn;
          Alcotest.test_case "styles and wide characters move a mark by cells"
            `Quick test_styles_and_wide_characters_move_a_mark_by_cells;
          Alcotest.test_case "a cut row keeps what is left of the mark" `Quick
            test_a_cut_row_keeps_what_is_left_of_the_mark;
          Alcotest.test_case "an escape that is not a mark is kept" `Quick
            test_an_escape_that_is_not_a_mark_is_kept;
          Alcotest.test_case "a mark opened inside another closes it" `Quick
            test_a_mark_opened_inside_another_closes_it;
          Alcotest.test_case "a reset registry answers no old mark" `Quick
            test_a_reset_registry_answers_no_old_mark;
          Alcotest.test_case "rows count from one" `Quick test_rows_count_from_one;
          Alcotest.test_case "an empty mark answers nothing" `Quick
            test_an_empty_mark_answers_nothing;
          Alcotest.test_case "two registries read only their own marks" `Quick
            test_two_registries_read_only_their_own_marks ] ) ]
