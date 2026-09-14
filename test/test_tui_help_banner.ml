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
(* The sheet's key column is where the five mark sections put a glyph, and a
   glyph is one cell in two or three bytes. Padded with [%-*s], which counts
   bytes, every mark row sat at its own indent: the word beside the paused
   mark started two columns left of the word beside "?" one row under it.

   Read off the drawn rows rather than the padding code, and over the keeper
   marks because that section holds a one-byte key, a two-byte one and a
   three-byte one. *)
let test_the_mark_rows_share_one_column () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  let rows =
    List.map Masc_tui_theme.strip_sgr
      (Masc_tui_render_prim.help_lines ~width:90 state)
  in
  let entries =
    match List.assoc_opt "Keeper marks" (Masc_tui_keys.help_sections ()) with
    | Some entries -> entries
    | None -> Alcotest.fail "the sheet has no Keeper marks section"
  in
  let column_of (_, action) =
    match List.find_opt (fun row -> contains ("  " ^ action) row) rows with
    | None -> Alcotest.failf "the sheet drew no row for %S" action
    | Some row ->
        let rec seek i =
          if i + String.length action > String.length row then
            Alcotest.failf "row lost %S: %S" action row
          else if String.equal (String.sub row i (String.length action)) action
          then Masc_tui_message_layout.display_width (String.sub row 0 i)
          else seek (i + 1)
        in
        seek 0
  in
  match entries with
  | [] -> Alcotest.fail "the Keeper marks section is empty"
  | first :: rest ->
      let expected = column_of first in
      List.iter
        (fun entry ->
          Alcotest.(check int)
            (Printf.sprintf "%S starts where the first mark's word does"
               (snd entry))
            expected (column_of entry))
        rest

let test_the_masthead_spends_two_rows () =
  Alcotest.(check int) "the name and a blank row" 2 (List.length (masthead ()))

(* One heading style across the sheet. The section being read wears the filled
   mark and every other section, the slash commands included, the hollow one,
   each under the name the key table gives it. *)
let test_sections_share_one_heading_style () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  let drawn =
    List.map Masc_tui_theme.strip_sgr (Masc_tui_render_prim.help_lines ~width:200 state)
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
    List.map Masc_tui_theme.strip_sgr (Masc_tui_render_prim.help_lines ~width:200 state)
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

(* An entry's text wraps under the column every entry's text starts at. Cut to
   the column, 23 of the 29 slash-command summaries at 120 cells ended in an
   ellipsis where they said what the command does. *)
let test_an_entry_wraps_under_its_text () =
  let state = create_state ~workspace:"" ~port:0 ~refresh_interval:0. () in
  state.view <- Overview;
  let width = 40 in
  let drawn =
    List.map Masc_tui_theme.strip_sgr
      (Masc_tui_render_prim.help_lines ~width state)
  in
  let joined = String.concat " " (List.map String.trim drawn) in
  let squeeze text =
    String.concat " "
      (List.filter (fun word -> word <> "") (String.split_on_char ' ' text))
  in
  (match Masc_tui_keys.help_sections ~current:Overview () with
   | [] -> Alcotest.fail "no help sections"
   | (_, entries) :: _ ->
       List.iter
         (fun (_, action) ->
           Alcotest.(check bool)
             (Printf.sprintf "%S is drawn whole" action)
             true
             (contains (squeeze action) (squeeze joined)))
         entries);
  List.iter
    (fun (cmd : Masc_tui_command.command_help) ->
      Alcotest.(check bool)
        (Printf.sprintf "%S is drawn whole" cmd.summary)
        true
        (contains (squeeze cmd.summary) (squeeze joined)))
    Masc_tui_command.catalog;
  let continued =
    List.filter
      (fun row ->
        String.length row > 19
        && String.sub row 0 19 = String.make 19 ' '
        && row.[19] <> ' ')
      drawn
  in
  Alcotest.(check bool) "a key's text continues under the text column" true
    (continued <> []);
  List.iter
    (fun row ->
      if not (String.starts_with ~prefix:"  /" row) then
        Alcotest.(check bool)
          (Printf.sprintf "%S fits %d cells" row width)
          true
          (Masc_tui_message_layout.display_width row <= width))
    drawn

let () =
  Alcotest.run "masc_tui_help_banner"
    [ ( "masthead"
      , [ Alcotest.test_case "the product, not the chrome" `Quick
            test_the_masthead_names_the_product_and_nothing_else_twice
        ; Alcotest.test_case "the mark rows share one column" `Quick
            test_the_mark_rows_share_one_column
        ; Alcotest.test_case "the masthead spends two rows" `Quick
            test_the_masthead_spends_two_rows
        ; Alcotest.test_case "keys are not wrapped in brackets" `Quick
            test_keys_are_not_wrapped_in_brackets
        ; Alcotest.test_case "sections share one heading style" `Quick
            test_sections_share_one_heading_style
        ; Alcotest.test_case "an entry wraps under its text" `Quick
            test_an_entry_wraps_under_its_text
        ] )
    ]
