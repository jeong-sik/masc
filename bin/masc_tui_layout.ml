let nonnegative_width width = max 0 width

type automation_schedule_row =
  { status : string
  ; requested_clock : string
  ; recurrence : string
  ; summary : string
  }

(* Keep the summary on every main row. A single long recurrence must not make
   every other row pad to its width and disappear at the frame's right edge.
   The variable area gives at least a third to the summary; a recurrence that
   cannot fit there gets a labelled continuation with its full text. *)
let automation_schedule_lines ~inner_width ~status_cells ~clock_cells rows =
  let module Text = Masc_tui_message_layout in
  let lead_cells = 2 + max 0 status_cells + 1 + max 0 clock_cells + 2 in
  let variable_cells = max 0 (inner_width - lead_cells - 1) in
  let summary_reserve = max 1 (variable_cells / 3) in
  let recurrence_limit = max 0 (variable_cells - summary_reserve) in
  let recurrence_cells =
    List.fold_left
      (fun widest (row : automation_schedule_row) ->
         let width = Text.display_width row.recurrence in
         if width <= recurrence_limit then max widest width else widest)
      0 rows
  in
  List.concat_map
    (fun (row : automation_schedule_row) ->
       let lead =
         "  " ^ Text.fit_width row.status status_cells ^ " "
         ^ Text.fit_width row.requested_clock clock_cells ^ "  "
       in
       if Text.display_width row.recurrence <= recurrence_limit then
         [ lead ^ Text.fit_width row.recurrence recurrence_cells ^ " " ^ row.summary ]
       else
         let label = "    recurrence: " in
         let continuation_width = max 1 (inner_width - Text.display_width label) in
         let continuation =
           Text.wrap_words ~max_cells:continuation_width row.recurrence
           |> List.map (fun line -> label ^ line)
         in
         (lead ^ row.summary) :: continuation)
    rows
;;

let keeper_context_bar_width ~inner_width =
  nonnegative_width (min 30 (inner_width - 40))

type board_read_allocation = {
  body_rows : int;
  comment_rows : int;
}

let board_comment_share = 3
let board_comment_floor_rows = 5
let board_read_box_rows = 7
let board_read_footer_rows = 1
let board_read_position_rows = 1

let allocate_board_read ~terminal_rows ~body_line_count ~comment_line_count =
  let comment_line_count = max 0 comment_line_count in
  let comment_chrome_rows = if comment_line_count > 0 then 2 else 0 in
  let allocate ~position_rows =
    let available =
      max 0
        (terminal_rows - board_read_box_rows - board_read_footer_rows
         - comment_chrome_rows - position_rows)
    in
    let minimum_body_rows = if body_line_count > 0 then 1 else 0 in
    let comment_ceiling =
      max board_comment_floor_rows
        (max
           (available - max 0 body_line_count)
           (available / board_comment_share))
    in
    let comment_rows =
      min (min comment_ceiling comment_line_count)
        (max 0 (available - minimum_body_rows))
    in
    let body_rows = max 0 (available - comment_rows) in
    { body_rows; comment_rows }
  in
  let unpositioned = allocate ~position_rows:0 in
  if
    body_line_count > unpositioned.body_rows
    || comment_line_count > unpositioned.comment_rows
  then allocate ~position_rows:board_read_position_rows
  else unpositioned

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

let project_board_read_scroll ~body_line_count ~body_rows ~comment_line_count
    ~comment_rows scroll =
  let body_line_count = max 0 body_line_count in
  let body_rows = max 0 body_rows in
  let comment_line_count = max 0 comment_line_count in
  let comment_rows = max 0 comment_rows in
  let maximum_body_offset = max 0 (body_line_count - body_rows) in
  let maximum_comment_offset = max 0 (comment_line_count - comment_rows) in
  let maximum_scroll = maximum_body_offset + maximum_comment_offset in
  let normalized_scroll = max 0 (min scroll maximum_scroll) in
  let body_offset = min normalized_scroll maximum_body_offset in
  let comment_offset =
    min maximum_comment_offset (normalized_scroll - body_offset)
  in
  { normalized_scroll; body_offset; comment_offset }

let board_read_side_body_minimum_cols = 78
let board_read_side_comment_cols = 40
let board_read_side_gutter_cols = 2

let board_read_side_minimum_cols =
  board_read_side_body_minimum_cols + board_read_side_gutter_cols
  + board_read_side_comment_cols

let board_read_side_layout ~cols =
  if cols < board_read_side_minimum_cols then None
  else
    Some
      ( cols - board_read_side_comment_cols - board_read_side_gutter_cols
      , board_read_side_comment_cols + board_read_side_gutter_cols )

type board_read_side_allocation = {
  body_rows : int;
  comment_rows : int;
}

let allocate_board_read_side ~terminal_rows ~body_line_count ~comment_line_count =
  let body_line_count = max 0 body_line_count in
  let comment_line_count = max 0 comment_line_count in
  let available =
    max 0
      (terminal_rows - board_read_box_rows - board_read_footer_rows
       - board_read_position_rows)
  in
  let comment_header_rows = if comment_line_count > 0 then 1 else 0 in
  let minimum_comment_rows =
    if comment_line_count > 0 then comment_header_rows + 1 else 0
  in
  let comment_rows =
    if comment_line_count > 0 && available >= minimum_comment_rows then available
    else 0
  in
  let body_rows = if body_line_count > 0 then available else 0 in
  { body_rows; comment_rows }
