(* The Keepers footer is built by hand because it says which actions this
   keeper offers -- a key the keeper cannot answer is dimmed rather than
   dropped. What it must not do is build items the footer cannot read: written
   "key label" and joined with a middle dot, the whole legend arrived as one
   item, so Masc_tui_footer could not drop anything and cut the row mid-word.
   The exit key is last in the list, so the exit key went first. *)

open Masc_tui_types

let contains needle haystack =
  let n = String.length needle in
  let rec seek i =
    i + n <= String.length haystack
    && (String.equal (String.sub haystack i n) needle || seek (i + 1))
  in
  seek 0

let make_state () = create_state ~workspace:"" ~port:0 ~refresh_interval:0. ()

let legend () =
  Masc_tui_render_prim.keeper_action_hints (make_state ()) None

let test_the_legend_is_split_into_items () =
  let items =
    Masc_tui_footer.split_on_double_space (String.trim (legend ()))
    |> List.filter (fun item -> not (String.equal (String.trim item) ""))
  in
  Alcotest.(check bool) "more than one item" true (List.length items > 1);
  List.iter
    (fun item ->
      Alcotest.(check bool)
        (Printf.sprintf "%S names its key before a colon"
           (Masc_tui_theme.strip_sgr item))
        true
        (Option.is_some (String.index_opt item ':')))
    items

let test_the_exit_key_survives_a_row_that_cannot_hold_the_legend () =
  (* 60 columns is where the row stopped holding the legend. *)
  let drawn =
    Masc_tui_footer.line ~dim:"" ~reset:"" ~max_cells:60 ~port:8935
      ~hints:(legend ()) ()
  in
  let plain = Masc_tui_theme.strip_sgr drawn in
  Alcotest.(check bool) "the row is cut" true (contains "\xe2\x80\xa6" plain);
  Alcotest.(check bool) "and the way out is still on it" true
    (contains "q:quit" plain)

let () =
  Alcotest.run "masc_tui_keeper_legend"
    [ ( "keeper legend"
      , [ Alcotest.test_case "items the footer can split" `Quick
            test_the_legend_is_split_into_items
        ; Alcotest.test_case "the exit key survives the cut" `Quick
            test_the_exit_key_survives_a_row_that_cannot_hold_the_legend
        ] )
    ]
