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
  body_offset : int;
  comment_offset : int;
}

let project_board_read_scroll ~body_line_count ~body_rows ~comment_line_count
    ~comment_rows ~body_scroll ~comment_scroll =
  let body_offset =
    max 0 (min body_scroll (max 0 (body_line_count - body_rows)))
  in
  let comment_offset =
    max 0 (min comment_scroll (max 0 (comment_line_count - comment_rows)))
  in
  { body_offset; comment_offset }

let board_read_side_body_minimum_cols = 78
let board_read_side_comment_cols = 40
let board_read_side_gutter_cols = 2

let board_read_side_minimum_cols =
  board_read_side_body_minimum_cols + board_read_side_gutter_cols
  + board_read_side_comment_cols

let board_read_side_layout ~cols =
  if cols < board_read_side_minimum_cols then None
  else
    (* Keep the old 78/40 minimum. Above it, give half of each extra pair
       of cells to comments and the other half to the post. *)
    let comment_cols =
      board_read_side_comment_cols
      + ((cols - board_read_side_minimum_cols) / 2)
      + board_read_side_gutter_cols
    in
    Some (cols - comment_cols, comment_cols)

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

type section = { floor : int; want : int }
type allocation = { rows : int list; filler : int }

(* Two passes, because one hands the rows out first come first served: the
   section ahead takes everything it wants, and the one behind it keeps only
   what was set aside for it by hand. On the Overview that was one Task row
   whatever the terminal offered (#38607, #38911). Floors are paid in part
   when the budget runs out inside one; paying them whole or not at all would
   let one more row move a floor from a later section to an earlier one, and
   the later section would shrink as the terminal grew. *)
let allocate ~budget sections =
  let want (section : section) = max 0 section.want in
  let floor (section : section) = max 0 (min section.floor (want section)) in
  let give remaining rows =
    let given = min rows remaining in
    (remaining - given, given)
  in
  let remaining, floors =
    List.fold_left_map
      (fun remaining section -> give remaining (floor section))
      (max 0 budget) sections
  in
  let filler, rows =
    List.fold_left_map
      (fun remaining (section, floored) ->
        let remaining, grown = give remaining (want section - floored) in
        (remaining, floored + grown))
      remaining
      (List.combine sections floors)
  in
  { rows; filler }
