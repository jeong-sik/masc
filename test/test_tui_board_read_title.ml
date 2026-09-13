(* The Board reader's title row. A short id drew "[post-a      ]", padded inside
   its brackets, and replies were "💬3" or "c0" depending on the count. *)

let title ?(hearth = None) ?(votes = 1) ?(replies = 0) id =
  Masc_tui_theme.strip_sgr
    (Masc_tui_render_prim.board_read_title ~screen:"Board" ~id ~hearth ~votes ~replies)

let test_a_short_id_is_not_padded () =
  Alcotest.(check string) "the id sits tight in its brackets"
    "Board  [post-a]  ▲+1  💬0" (title "post-a")

let test_a_long_id_is_folded_to_the_column () =
  let row = title "post-0123456789abcdef" in
  let opening = String.index row '[' and closing = String.index row ']' in
  let inside = String.sub row (opening + 1) (closing - opening - 1) in
  Alcotest.(check bool) "within the list's ID column" true
    (Masc_tui_message_layout.display_width inside <= 12);
  let n = String.length "…" in
  let rec has i = i + n <= String.length inside && (String.sub inside i n = "…" || has (i + 1)) in
  Alcotest.(check bool) "and visibly folded" true (has 0)

let test_replies_have_one_spelling () =
  Alcotest.(check string) "a count" "Board  [p]   0  💬3" (title ~votes:0 ~replies:3 "p")

(* The shared bracket: the value sits tight, and only an overrun is folded. *)
let test_a_bracketed_value_is_never_padded_inside () =
  Alcotest.(check string) "short" "[executing]"
    (Masc_tui_render_prim.bracketed ~max_cells:10 "executing");
  Alcotest.(check string) "exact" "[confirming]"
    (Masc_tui_render_prim.bracketed ~max_cells:10 "confirming");
  let folded = Masc_tui_render_prim.bracketed ~max_cells:6 "awaiting_confirmation" in
  Alcotest.(check int) "an overrun folds to the width, brackets aside" 8
    (Masc_tui_message_layout.display_width folded)

let () =
  Alcotest.run "tui_board_read_title"
    [ ( "board read title"
      , [ Alcotest.test_case "a short id is not padded" `Quick test_a_short_id_is_not_padded
        ; Alcotest.test_case "a long id is folded to the column" `Quick
            test_a_long_id_is_folded_to_the_column
        ; Alcotest.test_case "replies have one spelling" `Quick test_replies_have_one_spelling
        ; Alcotest.test_case "a bracketed value is never padded inside" `Quick
            test_a_bracketed_value_is_never_padded_inside
        ] )
    ]
