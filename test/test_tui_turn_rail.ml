(** The bracket a turn draws down the left margin.

    A chat pane interleaves one keeper's turn with broadcasts, journal commits
    and other turns on a single clock, and nothing said which rows belonged to
    which turn. Worse, a turn's reasoning, tool calls and skills sat at the
    same depth as its reply -- same column, same indent -- so what a turn did
    read as a sibling of what it said.

    These check the rows [visible_rows] actually returns. A classifier that is
    right while nothing draws it proves nothing about the pane. *)

open Alcotest
module Layout = Masc_tui_message_layout

let entry ?(turn_rail = Layout.Rail_none) ?(style = Layout.Keeper)
    ?(role = "keeper.one") body : Layout.entry =
  { style
  ; timestamp = "01:41:00"
  ; timeline_bucket = None
  ; role_label = Layout.align_role_label ~style role
  ; role_label_mark_cells = Layout.role_label_mark_cells ~style ()
  ; request_label = ""
  ; body
  ; markdown_source = Layout.Markdown_streaming
  ; turn_rail
  ; action = Layout.Action_none
  }
;;

let every_rail =
  [ Layout.Rail_opens
  ; Layout.Rail_says
  ; Layout.Rail_does
  ; Layout.Rail_closes
  ; Layout.Rail_joins Layout.Siding_journal
  ; Layout.Rail_joins Layout.Siding_arrival
  ; Layout.Rail_none
  ]
;;

let body_rows ?(inner_width = 60) entry =
  Layout.visible_rows ~origin:Layout.Origin_bare ~inner_width ~height:40
    [ entry ]
  |> List.filter (fun (row : Layout.row) -> row.kind = Layout.Body)
;;

(* The glyph is what survives NO_COLOR, so it has to be a shape and it has to
   fit the one cell the margin budgeted for it. A wide glyph would push the
   badge and every body a column right. *)
let test_every_piece_is_one_cell () =
  List.iter
    (fun rail ->
      check int "one cell" 1
        (Layout.display_width (Layout.turn_rail_glyph rail)))
    every_rail
;;

(* The budget is what the layout subtracts from the body, so the margin has
   to spend all of it. Measuring the widths against each other only says they
   agree; it does not say they agree with [turn_rail_cells]. They did not: the
   gutter drew three lead cells and one glyph and stopped, and the cell the
   budget keeps between the glyph and the clock was taken by the label's first
   character instead. *)
let test_the_gutter_spends_its_whole_budget () =
  List.iter
    (fun rail ->
      check int "the gutter is the budget wide" Layout.turn_rail_cells
        (Layout.display_width (Layout.turn_rail_gutter rail)))
    every_rail
;;

(* An alphabet is closed when each mark means one thing. Two rail pieces
   sharing a glyph would put "the turn ended" and "the turn did this" behind
   the same shape. *)
let test_the_drawn_pieces_are_distinct () =
  let drawn =
    List.filter (fun rail -> rail <> Layout.Rail_none) every_rail
    |> List.map Layout.turn_rail_glyph
  in
  (* Five shapes, not six: both sidings meet the line the same way, and what
     kind of siding it was is in the run leading up to it. *)
  check int "five distinct glyphs" 5
    (List.length (List.sort_uniq String.compare drawn));
  check string "nothing to hang draws a blank" " "
    (Layout.turn_rail_glyph Layout.Rail_none)
;;

(* The margin's width is what the body's width is taken from. A rail column
   that appeared with the rail would re-wrap every body under a scroll position
   taken before it, which is how a reader loses their place. *)
let test_the_rail_costs_the_same_whatever_it_draws () =
  let widths =
    List.map
      (fun turn_rail ->
        match body_rows (entry ~turn_rail "a reply worth two words") with
        | row :: _ -> Layout.display_width row.Layout.gutter
        | [] -> failwith "no body row")
      every_rail
  in
  check int "one gutter width across every rail" 1
    (List.length (List.sort_uniq Int.compare widths))
;;

(* One row is not a hierarchy. Marking it would put a rail on nearly every row
   of an ordinary conversation, which is where a reader stops seeing it. *)
let test_a_turn_of_one_row_draws_nothing () =
  match body_rows (entry ~turn_rail:Layout.Rail_none "hello") with
  | row :: _ ->
      check string "blank rail cells"
        (String.make row.Layout.gutter_rail_cells ' ')
        (Layout.take_cells row.Layout.gutter row.Layout.gutter_rail_cells)
  | [] -> failwith "no body row"
;;

(* The glyph sits past the siding run, not at the head of the gutter: a
   turn-only row pays those cells as blanks so the line stays in one column
   whether or not anything arrived beside it. *)
let rail_glyphs rows =
  List.map
    (fun (row : Layout.row) ->
      Layout.take_cells
        (Layout.drop_cells row.gutter Layout.siding_lead_cells)
        1)
    rows
;;

(* The run is where a siding says what it is. Both kinds meet the line with
   the same glyph, so if the runs matched too a journal commit and another
   agent's broadcast would be one shape. *)
let test_the_siding_runs_tell_the_kinds_apart () =
  let run rail =
    match body_rows (entry ~turn_rail:rail "arrived") with
    | row :: _ -> Layout.take_cells row.Layout.gutter Layout.siding_lead_cells
    | [] -> failwith "no body row"
  in
  let journal = run (Layout.Rail_joins Layout.Siding_journal) in
  let arrival = run (Layout.Rail_joins Layout.Siding_arrival) in
  check bool "the two runs differ" true (journal <> arrival);
  check int "the journal run fills the column" Layout.siding_lead_cells
    (Layout.display_width journal);
  check int "the arrival run fills it too" Layout.siding_lead_cells
    (Layout.display_width arrival)
;;

(* An arrival joins once. A wrapped broadcast that drew the join on every row
   would read as several arrivals, and one that fell back to the turn's own
   line would say the turn produced it. *)
let test_a_wrapped_arrival_joins_once_and_never_joins_the_turn () =
  let rows =
    body_rows ~inner_width:40
      (entry ~turn_rail:(Layout.Rail_joins Layout.Siding_arrival)
         ~style:Layout.Inbound ~role:"geek-scout" (String.make 200 'x'))
  in
  match rail_glyphs rows with
  | first :: rest ->
      check string "the first row joins"
        (Layout.turn_rail_glyph (Layout.Rail_joins Layout.Siding_arrival))
        first;
      List.iter
        (fun glyph ->
          check string "and the rest hang on nothing"
            (Layout.turn_rail_glyph Layout.Rail_none)
            glyph)
        rest
  | [] -> failwith "no body row"
;;

(* The bracket runs the height of the entry. Broken at every wrap it would read
   as one turn per screen line, which is the opposite of what it is for. *)
let test_the_opening_corner_stays_on_the_first_row () =
  let rows =
    body_rows ~inner_width:40
      (entry ~turn_rail:Layout.Rail_opens (String.make 200 'x'))
  in
  check bool "more than one row" true (List.length rows > 1);
  match rail_glyphs rows with
  | first :: rest ->
      check string "corner opens the entry"
        (Layout.turn_rail_glyph Layout.Rail_opens) first;
      List.iter
        (fun glyph ->
          check string "wrapped rows continue the trunk"
            (Layout.turn_rail_glyph Layout.Rail_says) glyph)
        rest
  | [] -> failwith "no body row"
;;

(* A turn's last entry can wrap ten rows. Closing it at the top of its own last
   paragraph would end the turn where the paragraph began. *)
let test_the_closing_corner_lands_on_the_last_row () =
  let rows =
    body_rows ~inner_width:40
      (entry ~turn_rail:Layout.Rail_closes (String.make 200 'x'))
  in
  let glyphs = rail_glyphs rows in
  let last = List.nth glyphs (List.length glyphs - 1) in
  check string "corner closes the entry"
    (Layout.turn_rail_glyph Layout.Rail_closes) last;
  List.iteri
    (fun index glyph ->
      if index < List.length glyphs - 1 then
        check string "earlier rows continue the trunk"
          (Layout.turn_rail_glyph Layout.Rail_says) glyph)
    glyphs
;;

(* Work hangs off the trunk on the row it starts, and its wrapped output goes
   on carrying the turn. A branch repeated down a tool block would draw one
   call per line of output. *)
let test_work_branches_once_and_then_carries_the_turn () =
  let rows =
    body_rows ~inner_width:40
      (entry ~turn_rail:Layout.Rail_does ~style:Layout.Tool ~role:"TOOLS"
         (String.make 200 'x'))
  in
  match rail_glyphs rows with
  | first :: rest ->
      check string "the branch opens the block"
        (Layout.turn_rail_glyph Layout.Rail_does) first;
      List.iter
        (fun glyph ->
          check string "its output stays inside the turn"
            (Layout.turn_rail_glyph Layout.Rail_says) glyph)
        rest
  | [] -> failwith "no body row"
;;

(* [gutter_rail_cells] is the layout's own count of what it placed. A renderer
   measuring the glyph a second time is how the two drift, and a boundary that
   overran the label offset would colour a clock digit as though it were the
   rail. *)
let test_the_rail_boundary_is_inside_the_label_offset () =
  List.iter
    (fun turn_rail ->
      match body_rows (entry ~turn_rail "reply") with
      | row :: _ ->
          check bool "rail cells are the head of the label offset" true
            (row.Layout.gutter_rail_cells <= row.Layout.gutter_label_at);
          check int "the gutter is the run, the glyph and its separator"
            row.Layout.gutter_rail_cells
            (Layout.display_width
               (Layout.take_cells row.Layout.gutter
                  row.Layout.gutter_rail_cells))
      | [] -> failwith "no body row")
    every_rail
;;

(* Losing track of who is talking costs more than losing the bracket. The same
   order the speaker mark is dropped in. *)
let test_a_pane_too_narrow_drops_the_rail_not_the_name () =
  let rail_cells_at inner_width =
    match body_rows ~inner_width (entry ~turn_rail:Layout.Rail_does "x") with
    | row :: _ -> row.Layout.gutter_rail_cells
    | [] -> failwith "no body row"
  in
  (* The bar is the whole label plus the rail, out of what the floored body can
     spare. One cell either side of where the two meet. *)
  let label_cells =
    Layout.display_width
      (Layout.align_role_label ~style:Layout.Keeper "keeper.one")
  in
  let threshold = label_cells + Layout.turn_rail_cells + 2 + 4 in
  check int "a pane with room draws the rail" Layout.turn_rail_cells
    (rail_cells_at threshold);
  check int "a pane with none drops it" 0 (rail_cells_at (threshold - 1));
  match
    body_rows ~inner_width:(threshold - 1)
      (entry ~turn_rail:Layout.Rail_does "x")
  with
  | row :: _ ->
      check bool "the speaker survives" true
        (String.length (String.trim row.Layout.gutter) > 0)
  | [] -> failwith "no body row"
;;

(* The rail is charged to the margin, not to the badge. Taken out of the label
   column instead, the longest built-in label would have lost its tail:
   THINKING is exactly the width a narrow column leaves. *)
let test_the_rail_does_not_eat_the_badge () =
  let name_of turn_rail =
    match
      body_rows ~inner_width:80
        (entry ~turn_rail ~style:Layout.Thinking ~role:"THINKING" "reasoning")
    with
    | row :: _ -> String.trim (Layout.drop_cells row.gutter row.gutter_rail_cells)
    | [] -> failwith "no body row"
  in
  List.iter
    (fun turn_rail ->
      check string "the label reads the same with a rail"
        (name_of Layout.Rail_none) (name_of turn_rail))
    every_rail
;;

(* The fold marker sits at the end of the first row, so that is the row a
   press has to land on. A continuation carrying the action would take a press
   that opens something the reader cannot see the handle for. *)
let test_only_the_first_row_carries_the_action () =
  let rows =
    body_rows ~inner_width:40
      { (entry ~turn_rail:Layout.Rail_says (String.make 200 'x')) with
        Layout.action = Layout.Action_unfold_argument
      }
  in
  match rows with
  | [] -> failwith "no body row"
  | first :: rest ->
      check bool "the first row is pressable" true
        (first.Layout.action = Layout.Action_unfold_argument);
      List.iter
        (fun (row : Layout.row) ->
          check bool "and no continuation is" true
            (row.Layout.action = Layout.Action_none))
        rest
;;

let () =
  run "tui turn rail"
    [ ( "glyphs"
      , [ test_case "every piece is one cell" `Quick test_every_piece_is_one_cell
        ; test_case "the gutter spends its whole budget" `Quick
            test_the_gutter_spends_its_whole_budget
        ; test_case "the drawn pieces are distinct" `Quick
            test_the_drawn_pieces_are_distinct
        ] )
    ; ( "geometry"
      , [ test_case "the rail costs the same whatever it draws" `Quick
            test_the_rail_costs_the_same_whatever_it_draws
        ; test_case "the rail boundary is inside the label offset" `Quick
            test_the_rail_boundary_is_inside_the_label_offset
        ; test_case "a pane too narrow drops the rail, not the name" `Quick
            test_a_pane_too_narrow_drops_the_rail_not_the_name
        ; test_case "the rail does not eat the badge" `Quick
            test_the_rail_does_not_eat_the_badge
        ] )
    ; ( "the bracket"
      , [ test_case "a turn of one row draws nothing" `Quick
            test_a_turn_of_one_row_draws_nothing
        ; test_case "the opening corner stays on the first row" `Quick
            test_the_opening_corner_stays_on_the_first_row
        ; test_case "the closing corner lands on the last row" `Quick
            test_the_closing_corner_lands_on_the_last_row
        ; test_case "the siding runs tell the kinds apart" `Quick
            test_the_siding_runs_tell_the_kinds_apart
        ; test_case "a wrapped arrival joins once" `Quick
            test_a_wrapped_arrival_joins_once_and_never_joins_the_turn
        ; test_case "only the first row carries the action" `Quick
            test_only_the_first_row_carries_the_action
        ; test_case "work branches once and then carries the turn" `Quick
            test_work_branches_once_and_then_carries_the_turn
        ] )
    ]
;;
