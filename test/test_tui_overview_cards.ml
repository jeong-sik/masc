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

let indent = "  "

(* The rows the plain layout is owed for the first [kept] of [given], counted
   here from the lines of the reasons and not asked of the function under test:
   a heading, the lines, and a row that says some were left out. *)
let owed_height ~inner given kept =
  let cells = inner - Layout.display_width indent in
  let lines =
    List.fold_left
      (fun sum reason -> sum + List.length (Cards.reason_lines ~cells reason))
      0 (take kept given)
  in
  1 + lines + if kept < List.length given then 1 else 0

(* How many reasons the plain layout owes: the most that fit in [rows] together
   with their note, none when not even the first does. *)
let owed_count ~inner ~rows given =
  let fits kept = owed_height ~inner given kept <= rows in
  List.fold_left
    (fun best kept -> if fits kept then kept else best)
    0
    (List.init (List.length given) (fun index -> index + 1))

(* The rows themselves, built from the same pieces the layout is made of. *)
let owed_rows ~inner given kept =
  let cells = inner - Layout.display_width indent in
  let omitted = List.length given - kept in
  match kept with
  | 0 -> []
  | _ ->
      (Some Masc_tui_ansi.Ansi.bold, " " ^ Cards.reasons_title (List.length given))
      :: List.concat_map
           (fun reason ->
              List.map (fun line -> None, indent ^ line) (Cards.reason_lines ~cells reason))
           (take kept given)
      @ if omitted > 0 then
          [ Some (Masc_tui_ansi.Theme.recede ()), indent ^ Masc_tui_card.more_text omitted ]
        else []

let rows_testable = pair (option string) string

let plain ~inner ~rows given = Cards.plain_reasons ~indent ~inner ~rows given

(* The rows are the heading, the lines of the first reasons that fit, and the
   note, whatever the width and the number of rows. *)
let test_the_rows_are_the_heading_the_first_reasons_and_the_note () =
  List.iter
    (fun inner ->
       List.iter
         (fun rows ->
            let kept = owed_count ~inner ~rows reasons in
            check (list rows_testable)
              (Printf.sprintf "rows at %d cells and %d rows" inner rows)
              (owed_rows ~inner reasons kept) (plain ~inner ~rows reasons))
         (List.init 25 Fun.id))
    [ 14; 26; 42; 82 ]

(* The edge of the rows: the whole list fits in exactly its height, and one row
   less leaves some out. *)
let test_the_reasons_fit_exactly_at_their_height () =
  List.iter
    (fun inner ->
       let needed = owed_height ~inner reasons (List.length reasons) in
       let all = plain ~inner ~rows:needed reasons in
       check int "as many rows as the height" needed (List.length all);
       check (list rows_testable) "all shown, no note"
         (owed_rows ~inner reasons (List.length reasons)) all;
       let short = plain ~inner ~rows:(needed - 1) reasons in
       check bool "one row less leaves some out" true
         (List.length short < needed && short <> []))
    [ 14; 26; 42; 82 ]

let test_no_reason_draws_no_row () =
  List.iter
    (fun rows -> check int "no rows" 0 (List.length (plain ~inner:40 ~rows [])))
    [ 0; 1; 5; 40 ]

(* The note row is kept back before any reason is taken, so the rows that hold
   the heading and the first reason alone still draw nothing while others are
   left out. One row more draws the heading, the first reason and the note. *)
let test_rows_too_few_for_the_first_reason_and_the_note_draw_nothing () =
  let inner = 40 in
  let first_with_note = owed_height ~inner reasons 1 in
  List.iter
    (fun rows -> check int "no rows" 0 (List.length (plain ~inner ~rows reasons)))
    (List.init first_with_note Fun.id);
  check int "the first reason and its note" first_with_note
    (List.length (plain ~inner ~rows:first_with_note reasons))

(* Over many lists, widths and row counts: the rows are those owed, in no more
   rows than were given, and a reason line fits the width. *)
let words =
  [| "keeper_fleet_safety:no_executable_keeper_fibers"; "a"; "bb"
   ; "configured_keeper_without_runtime_meta"; "운영자가"; "확인해야"; "하는"
   ; "이유"; "x"; "keeper_memory_execution:addon_unattached" |]

let random_reason state =
  String.concat " "
    (List.init (1 + Random.State.int state 6)
       (fun _ -> words.(Random.State.int state (Array.length words))))

let test_the_rows_owed_over_many_lists_widths_and_row_counts () =
  let state = Random.State.make [| 42 |] in
  let cases = ref 0 in
  for _ = 1 to 500 do
    let given = List.init (Random.State.int state 7) (fun _ -> random_reason state) in
    (* From four cells: the indent takes two and a letter two cells wide does
       not fit in one. *)
    let inner = 4 + Random.State.int state 59 in
    let rows = Random.State.int state 18 in
    let drawn = plain ~inner ~rows given in
    let kept = owed_count ~inner ~rows given in
    incr cases;
    check bool "no more rows than it was given" true (List.length drawn <= rows);
    check (list rows_testable) "the rows owed" (owed_rows ~inner given kept) drawn;
    List.iter
      (function
        | None, text ->
            check bool "a reason line fits its width" true
              (Layout.display_width (strip text) <= inner)
        | Some _, _ -> ())
      drawn
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
        ; test_case "the rows are the heading, the first reasons and the note" `Quick
            test_the_rows_are_the_heading_the_first_reasons_and_the_note
        ; test_case "the reasons fit exactly at their height" `Quick
            test_the_reasons_fit_exactly_at_their_height
        ; test_case "no reason draws no row" `Quick test_no_reason_draws_no_row
        ; test_case "rows too few for the first reason and the note draw nothing" `Quick
            test_rows_too_few_for_the_first_reason_and_the_note_draw_nothing
        ; test_case "the rows owed over many lists, widths and row counts" `Quick
            test_the_rows_owed_over_many_lists_widths_and_row_counts
        ] )
    ]
