let nonnegative_width width = max 0 width

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

let allocate_board_read ~terminal_rows ~body_line_count ~comment_count =
  let comment_count = max 0 comment_count in
  let comment_chrome_rows = if comment_count > 0 then 2 else 0 in
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
      min (min comment_ceiling comment_count)
        (max 0 (available - minimum_body_rows))
    in
    let body_rows = max 0 (available - comment_rows) in
    { body_rows; comment_rows }
  in
  let unpositioned = allocate ~position_rows:0 in
  if
    body_line_count > unpositioned.body_rows
    || comment_count > unpositioned.comment_rows
  then allocate ~position_rows:board_read_position_rows
  else unpositioned

type board_read_scroll = {
  normalized_scroll : int;
  body_offset : int;
  comment_offset : int;
}

let project_board_read_scroll ~body_line_count ~body_rows ~comment_count
    ~comment_rows scroll =
  let body_line_count = max 0 body_line_count in
  let body_rows = max 0 body_rows in
  let comment_count = max 0 comment_count in
  let comment_rows = max 0 comment_rows in
  let maximum_body_offset = max 0 (body_line_count - body_rows) in
  let maximum_comment_offset = max 0 (comment_count - comment_rows) in
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

let allocate_board_read_side ~terminal_rows ~body_line_count ~comment_count =
  let body_line_count = max 0 body_line_count in
  let comment_count = max 0 comment_count in
  let available =
    max 0
      (terminal_rows - board_read_box_rows - board_read_footer_rows
       - board_read_position_rows)
  in
  let minimum_body_rows = if body_line_count > 0 then 1 else 0 in
  let comment_header_rows = if comment_count > 0 then 1 else 0 in
  let minimum_comment_rows =
    if comment_count > 0 then comment_header_rows + 1 else 0
  in
  let comment_target =
    comment_header_rows
    + min comment_count (max 0 ((available / 2) - comment_header_rows))
  in
  let comment_rows =
    min (max 0 (available - minimum_body_rows))
      (max minimum_comment_rows comment_target)
  in
  let comment_rows =
    if comment_rows > 0 && comment_rows < minimum_comment_rows then 0
    else comment_rows
  in
  let body_rows = max 0 (available - comment_rows) in
  { body_rows; comment_rows }
