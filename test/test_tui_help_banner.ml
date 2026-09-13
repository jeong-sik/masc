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

let () =
  Alcotest.run "masc_tui_help_banner"
    [ ( "masthead"
      , [ Alcotest.test_case "the product, not the chrome" `Quick
            test_the_masthead_names_the_product_and_nothing_else_twice
        ; Alcotest.test_case "the masthead spends two rows" `Quick
            test_the_masthead_spends_two_rows
        ] )
    ]
