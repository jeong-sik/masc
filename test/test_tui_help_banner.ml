(* The cheat sheet's masthead. It scrolls with the sheet, so anything it is the
   only place for is lost the moment the reader pages down. It used to carry the
   close key, the hints key and the active surface -- all three of which are
   said by rows that stay: the overlay's title row is fixed chrome above the
   divider, and the sheet's first section names the active surface. *)

open Masc_tui_types

let contains needle haystack =
  let n = String.length needle in
  let rec seek i =
    i + n <= String.length haystack
    && (String.equal (String.sub haystack i n) needle || seek (i + 1))
  in
  seek 0

let masthead () =
  Masc_tui_render_prim.help_masthead
    (create_state ~workspace:"" ~port:0 ~refresh_interval:0. ())

let test_the_masthead_names_the_product_and_nothing_else_twice () =
  let rows = masthead () in
  let drawn = Masc_tui_theme.strip_sgr (String.concat "\n" rows) in
  Alcotest.(check bool) "it names the product" true
    (contains "Multi-Agent Shared Context" drawn);
  List.iter
    (fun repeated ->
      Alcotest.(check bool)
        (Printf.sprintf "it leaves %S to the rows that stay" repeated)
        false (contains repeated drawn))
    [ "[?]"; "[h]"; "Hints"; "Active:" ]

(* The masthead scrolls with the sheet and the title row above it already says
   MASC, so every row it spends is a row of keys a short terminal does not
   show. A name and the blank under it. *)
let test_the_masthead_spends_two_rows () =
  Alcotest.(check int) "the name and a blank row" 2 (List.length (masthead ()))

(* One heading style across the sheet. The section being read wears the filled
   mark and every other section, the slash commands included, the hollow one,
   each under the name the key table gives it. *)
let test_sections_share_one_heading_style () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  let drawn =
    List.map Masc_tui_theme.strip_sgr (Masc_tui_render_prim.help_lines state)
  in
  let starts prefix line = String.starts_with ~prefix line in
  let filled = List.filter (starts "\xe2\x97\x86 ") drawn in
  Alcotest.(check (list string)) "one filled heading, the surface being read"
    [ "\xe2\x97\x86 Overview" ] filled;
  Alcotest.(check bool) "Global keeps its own name" true
    (List.mem "\xe2\x97\x87 Global" drawn);
  Alcotest.(check bool) "the slash commands are a section like the rest" true
    (List.mem "\xe2\x97\x87 Slash commands" drawn);
  List.iter
    (fun shout ->
      Alcotest.(check bool) (Printf.sprintf "no %S heading" shout) false
        (List.exists (fun line -> contains shout line) drawn))
    [ "ACTIVE:"; "GLOBAL NAVIGATION"; "SLASH COMMANDS" ]

(* The sheet's key column holds the key as the key table spells it. Wrapped in
   brackets, [/] for find and [ / ] for the bracket keys read as one key. *)
let test_keys_are_not_wrapped_in_brackets () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Board;
  let rows =
    List.map Masc_tui_theme.strip_sgr (Masc_tui_render_prim.help_lines state)
  in
  let has_row prefix =
    List.exists (fun row -> String.starts_with ~prefix row) rows
  in
  Alcotest.(check bool) "the bracket keys are drawn as themselves" true
    (has_row "  [ / ]  ");
  Alcotest.(check bool) "and j/k with nothing around it" true (has_row "  j/k  ");
  List.iter
    (fun wrapped ->
      Alcotest.(check bool) (Printf.sprintf "no %S" wrapped) false
        (List.exists (fun row -> contains wrapped row) rows))
    [ "[j/k]"; "[/]"; "[Tab]"; "[q]" ]

let () =
  Alcotest.run "masc_tui_help_banner"
    [ ( "masthead"
      , [ Alcotest.test_case "the product, not the chrome" `Quick
            test_the_masthead_names_the_product_and_nothing_else_twice
        ; Alcotest.test_case "the masthead spends two rows" `Quick
            test_the_masthead_spends_two_rows
        ; Alcotest.test_case "keys are not wrapped in brackets" `Quick
            test_keys_are_not_wrapped_in_brackets
        ; Alcotest.test_case "sections share one heading style" `Quick
            test_sections_share_one_heading_style
        ] )
    ]
