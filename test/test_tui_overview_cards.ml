(* The Dashboard's cards write every row out in full. These cases pin what the
   plain layout showed whole and an earlier card layout cut: the text of a long
   row is never lost, the selected row keeps its band on each of its lines, and
   the cards fall back to the plain rows whenever they do not fit. They check
   text that is present and the cells it takes, not how a screen reads. *)

open Alcotest
module Cards = Masc_tui_overview_cards
module Layout = Masc_tui_message_layout

let reset = Masc_tui_ansi.Ansi.reset

let strip = Masc_tui_theme.strip_sgr

let without_spaces text =
  String.concat "" (String.split_on_char ' ' text)

(* Rows as the Dashboard builds them: a short decision, a long one, a Keeper
   name with the note that its chat is saved only for this session, and text
   with wide characters. *)
let labels =
  [ "Held call · quill [call-1] · Execute"
  ; "Operator task · task-2183 · abandoned browser upload: held by codex-mcp-client, which has no Keeper queue"
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
    ?(decisions_whole = true) ?(actions = [])
    ?(continuation = [ 100, "Continue with kidsnote-slack-context-collector · save durability unconfirmed" ]) () =
  Cards.draw ~inner ~rows
    ~is_selected:(fun action -> action = selected)
    ~decisions:(List.mapi (fun index label -> index, label) decisions)
    ~decisions_whole
    ~continuation
    ~status:(fun ~cells:_ -> [ "Health: ok"; "Work: 3 done" ])
    ~actions

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

(* A window that holds only some decisions is named by its row range in the
   plain layout. The card title has no place for it, so no card is drawn,
   however many lines are free. *)
let test_a_partial_decision_window_draws_no_card () =
  check bool "the whole window draws the cards" true
    (Option.is_some (draw ~rows:200 ()));
  check bool "a partial window falls back to the plain rows" true
    (draw ~rows:200 ~decisions_whole:false () = None)

(* The reasons are an addition to the cards. Where the cards fit without them
   they are still drawn, and where they do not fit either way the caller draws
   the plain rows. *)
let test_the_reasons_never_cost_the_cards () =
  let reasons =
    [ "keeper_fleet_safety:no_executable_keeper_fibers"; "a second reason"; "a third reason" ]
  in
  let needed = List.length (rows_exn (draw ())) in
  check bool "exactly enough" true
    (Option.is_some (draw ~rows:needed ~actions:reasons ()));
  check bool "one line short" true
    (draw ~rows:(needed - 1) ~actions:reasons () = None)

let test_an_empty_decision_list_says_so_in_a_card () =
  let rows = rows_exn (draw ~decisions:[] ~continuation:[] ()) in
  check bool "the cards are still drawn" true (rows <> [])

(* The server's reasons for needing the operator. The card and the plain layout
   draw them through the same function, and the plain layout asks for as many
   whole reasons as the rows it has left. *)
let reasons =
  [ "keeper_fleet_safety:no_executable_keeper_fibers"
  ; "keeper_identity_drift:configured_keeper_without_runtime_meta"
  ; "keeper_memory_execution:addon_unattached"
  ; "운영자가 확인해야 하는 이유 하나"
  ; "x"
  ]

let take count list = List.filteri (fun index _ -> index < count) list

let test_a_reason_is_a_row_in_the_warning_colour () =
  List.iter
    (fun cells ->
       List.iter
         (fun reason ->
            let lines = Cards.reason_lines ~cells reason in
            check (list string) "the text of its lines is the row's"
              (Cards.row_lines ~cells reason) (List.map strip lines);
            List.iter
              (fun line ->
                 check bool "a line closes the colour it opened" true
                   (String.ends_with ~suffix:reset line))
              lines)
         reasons)
    [ 12; 24; 40; 80 ]

let test_the_title_names_how_many_reasons_there_are () =
  List.iter
    (fun count ->
       check bool (Printf.sprintf "%d is in the title" count) true
         (contains_flat ~needle:(string_of_int count) (Cards.reasons_title count)))
    [ 0; 1; 3; 12 ]

let height_of ~cells reasons ~omitted =
  Cards.reasons_height
    { Cards.shown = List.map (Cards.reason_lines ~cells) reasons; omitted }

let lines_in shown =
  List.fold_left (fun sum lines -> sum + List.length lines) 0 shown

(* The rows the reasons take are counted here from the lines, not asked of
   reasons_height: a heading, the lines, and a row that says some were left out. *)
let test_the_height_is_the_heading_the_lines_and_the_note () =
  List.iter
    (fun cells ->
       List.iter
         (fun rows ->
            let drawn = Cards.plain_reasons ~cells ~rows reasons in
            let expected =
              match drawn.Cards.shown with
              | [] -> 0
              | shown -> 1 + lines_in shown + if drawn.Cards.omitted > 0 then 1 else 0
            in
            check int
              (Printf.sprintf "height at %d cells and %d rows" cells rows)
              expected (Cards.reasons_height drawn))
         (List.init 25 Fun.id))
    [ 12; 24; 40; 80 ]

(* The edge of the rows: the whole list fits in exactly its height, and one row
   less leaves some out. *)
let test_the_reasons_fit_exactly_at_their_height () =
  List.iter
    (fun cells ->
       let needed = height_of ~cells reasons ~omitted:0 in
       let all = Cards.plain_reasons ~cells ~rows:needed reasons in
       check int "all shown" (List.length reasons) (List.length all.Cards.shown);
       check int "none left out" 0 all.Cards.omitted;
       check int "no more rows than the height" needed (Cards.reasons_height all);
       let short = Cards.plain_reasons ~cells ~rows:(needed - 1) reasons in
       check bool "one row less leaves some out" true (short.Cards.omitted > 0))
    [ 12; 24; 40; 80 ]

let test_no_reason_draws_no_row () =
  List.iter
    (fun rows ->
       let none = Cards.plain_reasons ~cells:40 ~rows [] in
       check int "nothing shown" 0 (List.length none.Cards.shown);
       check int "nothing left out" 0 none.Cards.omitted;
       check int "no rows" 0 (Cards.reasons_height none))
    [ 0; 1; 5; 40 ]

(* Not even the first reason fits with its heading: nothing is drawn, and the
   count says all of them were left out. *)
let test_rows_too_few_for_the_first_reason_draw_nothing () =
  let cells = 40 in
  let first_height = 1 + List.length (Cards.reason_lines ~cells (List.hd reasons)) in
  List.iter
    (fun rows ->
       let drawn = Cards.plain_reasons ~cells ~rows reasons in
       check int "nothing shown" 0 (List.length drawn.Cards.shown);
       check int "all left out" (List.length reasons) drawn.Cards.omitted;
       check int "no rows" 0 (Cards.reasons_height drawn))
    (List.init (first_height + 1) Fun.id)

(* Over many lists, widths and row counts: what is shown is the first reasons,
   whole and in order, in no more rows than it was given, and a reason it left
   out would not have fitted. *)
let words =
  [| "keeper_fleet_safety:no_executable_keeper_fibers"; "a"; "bb"
   ; "configured_keeper_without_runtime_meta"; "운영자가"; "확인해야"; "하는"
   ; "이유"; "x"; "keeper_memory_execution:addon_unattached" |]

let random_reason state =
  String.concat " "
    (List.init (1 + Random.State.int state 6)
       (fun _ -> words.(Random.State.int state (Array.length words))))

let test_the_reasons_shown_are_the_first_ones_whole_and_in_order () =
  let state = Random.State.make [| 42 |] in
  let cases = ref 0 in
  for _ = 1 to 500 do
    let given = List.init (Random.State.int state 7) (fun _ -> random_reason state) in
    (* From two cells: a letter two cells wide does not fit in one. *)
    let cells = 2 + Random.State.int state 59 in
    let rows = Random.State.int state 18 in
    let drawn = Cards.plain_reasons ~cells ~rows given in
    let count = List.length given and kept = List.length drawn.Cards.shown in
    incr cases;
    check bool "no more rows than it was given" true (Cards.reasons_height drawn <= rows);
    check int "each reason is shown or counted as left out" count (kept + drawn.Cards.omitted);
    check (list (list string)) "the first reasons, whole"
      (List.map (Cards.reason_lines ~cells) (take kept given)) drawn.Cards.shown;
    List.iter
      (List.iter (fun line ->
         check bool "a line fits its cells" true (Layout.display_width (strip line) <= cells)))
      drawn.Cards.shown;
    if drawn.Cards.omitted > 0 then
      check bool "the next reason would not have fitted" true
        (height_of ~cells (take (kept + 1) given) ~omitted:(count - kept - 1) > rows)
  done;
  check bool "the cases ran" true (!cases > 0)

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
        ; test_case "a partial decision window draws no card" `Quick
            test_a_partial_decision_window_draws_no_card
        ; test_case "the reasons never cost the cards" `Quick
            test_the_reasons_never_cost_the_cards
        ; test_case "an empty decision list still draws the cards" `Quick
            test_an_empty_decision_list_says_so_in_a_card
        ] )
    ; ( "reasons"
      , [ test_case "a reason is a row in the warning colour" `Quick
            test_a_reason_is_a_row_in_the_warning_colour
        ; test_case "the title names how many reasons there are" `Quick
            test_the_title_names_how_many_reasons_there_are
        ; test_case "the height is the heading, the lines and the note" `Quick
            test_the_height_is_the_heading_the_lines_and_the_note
        ; test_case "the reasons fit exactly at their height" `Quick
            test_the_reasons_fit_exactly_at_their_height
        ; test_case "no reason draws no row" `Quick test_no_reason_draws_no_row
        ; test_case "rows too few for the first reason draw nothing" `Quick
            test_rows_too_few_for_the_first_reason_draw_nothing
        ; test_case "the reasons shown are the first ones, whole and in order" `Quick
            test_the_reasons_shown_are_the_first_ones_whole_and_in_order
        ] )
    ]
