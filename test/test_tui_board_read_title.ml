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

(* The list holds one server page. The live board holds 107 posts and the page
   carries 50 of them, with no key that reaches the rest, so "(50)" beside the
   name said the board was fifty posts long. *)
let test_a_page_says_what_the_board_holds () =
  Alcotest.(check string) "the page, then the board"
    "(50 of 107)"
    (Masc_tui_render_prim.board_list_count_text ~loaded:50 ~holding:(Some 107))

let test_a_page_that_carries_everything_says_it_once () =
  Alcotest.(check string) "no difference to report" "(41)"
    (Masc_tui_render_prim.board_list_count_text ~loaded:41 ~holding:(Some 41))

(* Before the census answers there is no second number to give, and the count
   of what is on screen is still true. *)
let test_an_uncounted_board_keeps_the_page_count () =
  Alcotest.(check string) "the page alone" "(50)"
    (Masc_tui_render_prim.board_list_count_text ~loaded:50 ~holding:None)

(* The reader's index says the same pair its list header does. It read "(50)"
   one keypress after a header that read "(50 of 198)", so the page size read
   as the board's size to anyone who had not just seen the header. A surface
   with nothing more to hold is unchanged. *)
let sidebar_title ?holding labels =
  let buf = Buffer.create 256 in
  Masc_tui_render_prim.write_list_sidebar buf ~rows:10 ~cols:40 ~title:"Board"
    ~focused:false ?holding ~labels ~selected:0 ();
  Buffer.contents buf
;;

let holds needle text =
  let n = String.length needle and h = String.length text in
  let rec walk i =
    i + n <= h && (String.equal (String.sub text i n) needle || walk (i + 1))
  in
  walk 0
;;

let test_the_index_says_what_the_board_holds () =
  let labels = [ "one"; "two"; "three" ] in
  Alcotest.(check bool) "the page, then the board" true
    (holds "Board (3 of 9)" (sidebar_title ~holding:9 labels));
  Alcotest.(check bool) "an uncounted board keeps the page count" true
    (holds "Board (3)" (sidebar_title labels));
  Alcotest.(check bool) "a page that carries everything says it once" true
    (holds "Board (3)" (sidebar_title ~holding:3 labels))
;;

let () =
  Alcotest.run "tui_board_read_title"
    [ ( "board read title"
      , [ Alcotest.test_case "a short id is not padded" `Quick test_a_short_id_is_not_padded
        ; Alcotest.test_case "a long id is folded to the column" `Quick
            test_a_long_id_is_folded_to_the_column
        ; Alcotest.test_case "replies have one spelling" `Quick test_replies_have_one_spelling
        ; Alcotest.test_case "a bracketed value is never padded inside" `Quick
            test_a_bracketed_value_is_never_padded_inside
        ; Alcotest.test_case "a page says what the board holds" `Quick
            test_a_page_says_what_the_board_holds
        ; Alcotest.test_case "a page that carries everything says it once" `Quick
            test_a_page_that_carries_everything_says_it_once
        ; Alcotest.test_case "an uncounted board keeps the page count" `Quick
            test_an_uncounted_board_keeps_the_page_count
        ; Alcotest.test_case "the index says what the board holds" `Quick
            test_the_index_says_what_the_board_holds
        ] )
    ]
