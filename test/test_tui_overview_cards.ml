(* The Dashboard's cards write every row out in full. These cases pin what the
   plain layout showed whole and an earlier card layout cut: the text of a long
   row is never lost, the selected row keeps its band on each of its lines, and
   the cards fall back to the plain rows whenever they do not fit. They check
   text that is present and the cells it takes, not how a screen reads. *)

open Alcotest
module Cards = Masc_tui_overview_cards
module Layout = Masc_tui_message_layout

let strip = Masc_tui_theme.strip_sgr

let without_spaces text =
  String.concat "" (String.split_on_char ' ' text)

(* Rows as the Dashboard builds them: a short decision, a long one, a Keeper
   name with the note that its chat is saved only for this session, and text
   with wide characters. *)
let labels =
  [ "Held call · quill [call-1] · Execute"
  ; "Operator task · task-2183 · task-2183: held by codex-mcp-client, which has no Keeper queue"
  ; "Continue with kidsnote-slack-context-collector · save durability unconfirmed"
  ; "Question · wkbl-web-leader [ask…cd6af6b5] · 운영자가 세 후보를 주며 셋 중 하나냐고 되물었다"
  ; "x"
  ]

let test_a_row_never_loses_its_text () =
  List.iter
    (fun cells ->
       List.iter
         (fun label ->
            let lines = Cards.row_lines ~cells label in
            check bool "at least one line" true (lines <> []);
            check string
              (Printf.sprintf "nothing dropped at %d cells: %s" cells label)
              (without_spaces label)
              (without_spaces (String.concat "" lines));
            List.iter
              (fun line ->
                 check bool
                   (Printf.sprintf "a line fits %d cells" cells)
                   true
                   (Layout.display_width line <= cells))
              lines)
         labels)
    [ 12; 24; 40; 80 ]

let test_a_blank_row_is_still_one_line () =
  check int "an empty row keeps its place" 1 (List.length (Cards.row_lines ~cells:20 ""))

(* The two columns: what to do on the left, readings on the right. *)
let draw ?(inner = 120) ?(rows = 40) ?(selected = 1) ?(decisions = labels)
    ?(continuation = [ 100, "Continue with kidsnote-slack-context-collector · save durability unconfirmed" ]) () =
  Cards.draw ~inner ~rows
    ~is_selected:(fun action -> action = selected)
    ~decisions:(List.mapi (fun index label -> index, label) decisions)
    ~decision_title:"Needs your decision"
    ~continuation
    ~status:(fun ~cells:_ -> [ "Health: ok"; "Work: 3 done" ])

let rows_exn = function
  | Some rows -> rows
  | None -> fail "the cards should have fitted"

let test_every_line_is_the_inner_width () =
  List.iter
    (fun inner ->
       List.iter
         (fun line -> check int "line width" inner (Layout.display_width line))
         (rows_exn (draw ~inner ())))
    [ 90; 100; 120; 200 ]

(* The text between the first two vertical edges of a line: the left card's
   content. The two cards share each line, so wrapped text of the left card is
   read apart from the right one's. *)
let left_content line =
  match Astring.String.cuts ~sep:Masc_tui_theme.Box.v (strip line) with
  | _ :: content :: _ :: _ -> Some content
  | [] | [ _ ] | [ _; _ ] -> None

let contains_flat ~needle text =
  let needle = without_spaces needle and flat = without_spaces text in
  let n = String.length needle and h = String.length flat in
  let rec find i = i + n <= h && (String.sub flat i n = needle || find (i + 1)) in
  find 0

(* The long Continue row carries a warning the plain layout showed whole. *)
let test_a_long_continue_row_keeps_its_warning () =
  let left =
    rows_exn (draw ())
    |> List.filter_map left_content
    |> String.concat ""
  in
  check bool "the durability note is on screen" true
    (contains_flat ~needle:"save durability unconfirmed" left);
  check bool "and so is the wide-character row" true
    (contains_flat ~needle:"운영자가 세 후보를 주며 셋 중 하나냐고 되물었다" left)

let occurrences ~needle text =
  let n = String.length needle and h = String.length text in
  let rec loop i count =
    if i + n > h then count
    else if String.equal (String.sub text i n) needle then loop (i + n) (count + 1)
    else loop (i + 1) count
  in
  if n = 0 then 0 else loop 0 0

(* The selected row is one thing: its band is on every line it wraps to, and
   no other row has one. *)
let test_the_selected_row_has_a_band_on_each_of_its_lines () =
  let inner = 100 in
  let cells = Masc_tui_card.content_cells
      ~width:(List.hd (Masc_tui_card.column_widths ~inner_width:inner ~gap:2 ~columns:2)) in
  List.iteri
    (fun selected _ ->
       let drawn = String.concat "\n" (rows_exn (draw ~inner ~selected ())) in
       let expected = List.length (Cards.row_lines ~cells (List.nth labels selected)) in
       check int
         (Printf.sprintf "row %d has a band on each of its %d lines" selected expected)
         expected
         (occurrences ~needle:Masc_tui_theme.selection drawn))
    labels

let test_no_row_selected_has_no_band () =
  let drawn = String.concat "\n" (rows_exn (draw ~selected:(-1) ~continuation:[] ())) in
  check int "no band" 0 (occurrences ~needle:Masc_tui_theme.selection drawn)

(* Where the cards do not fit, the caller draws the plain rows. *)
let test_cards_fall_back_when_they_do_not_fit () =
  check bool "one column's width" true (draw ~inner:60 () = None);
  let needed = List.length (rows_exn (draw ())) in
  check bool "one line short" true (draw ~rows:(needed - 1) () = None);
  check bool "exactly enough" true (Option.is_some (draw ~rows:needed ()))

let test_an_empty_decision_list_says_so_in_a_card () =
  let rows = rows_exn (draw ~decisions:[] ~continuation:[] ()) in
  check bool "the cards are still drawn" true (rows <> [])

let () =
  run "tui overview cards"
    [ ( "rows"
      , [ test_case "a row never loses its text" `Quick test_a_row_never_loses_its_text
        ; test_case "a blank row is still one line" `Quick
            test_a_blank_row_is_still_one_line
        ] )
    ; ( "cards"
      , [ test_case "every line is the inner width" `Quick
            test_every_line_is_the_inner_width
        ; test_case "a long Continue row keeps its warning" `Quick
            test_a_long_continue_row_keeps_its_warning
        ; test_case "the selected row has a band on each of its lines" `Quick
            test_the_selected_row_has_a_band_on_each_of_its_lines
        ; test_case "no row selected has no band" `Quick test_no_row_selected_has_no_band
        ; test_case "cards fall back when they do not fit" `Quick
            test_cards_fall_back_when_they_do_not_fit
        ; test_case "an empty decision list still draws the cards" `Quick
            test_an_empty_decision_list_says_so_in_a_card
        ] )
    ]
