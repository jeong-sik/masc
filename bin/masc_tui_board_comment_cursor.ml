open Masc_tui_types

let ordered_ids comments =
  List.map
    (fun (_depth, comment) -> comment.bc_id)
    (Masc_tui_board_comment_thread.order comments)

let position ids cursor =
  Option.bind cursor (fun id -> List.find_index (String.equal id) ids)

let resolve ids cursor =
  Option.bind (position ids cursor) (List.nth_opt ids)

let select ids ~landing cursor =
  match resolve ids cursor with
  | Some id -> Some id
  | None -> (
      match resolve ids landing with
      | Some id -> Some id
      | None -> List.nth_opt ids 0)

let move ids ~landing cursor ~delta =
  match position ids cursor with
  | None -> select ids ~landing None
  | Some index ->
      List.nth_opt ids (max 0 (min (List.length ids - 1) (index + delta)))

let reveal_scroll ~scroll ~viewport_rows ~first_row ~row_count =
  if first_row < scroll then first_row
  else
    (* Written as a difference so a [scroll] still holding the end-of-reading
       sentinel cannot overflow. *)
    let bottom_aligned = first_row + row_count - viewport_rows in
    if bottom_aligned > scroll then min first_row bottom_aligned else scroll
