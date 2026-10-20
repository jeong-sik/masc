type source = {
  post : Masc_tui_types.board_post;
  detail :
    (Masc_tui_types.board_post * Masc_tui_types.board_comment list * string option)
      Masc_tui_board_detail.view;
  related_posts : Masc_tui_types.board_post list;
  keeper_names : string list;
  columns : int;
  styles : string list;
  table_frame : bool;
}

type comment_row =
  | Thread_note of string
  | Comment_text of { comment_id : string; text : string }

type rows = { body : string array; comments : comment_row array; initial_comment_offset : (string * int) option }

let comment_gutter_cells = 2

type t = { mutable retained : (source * rows) option }

let close_time seconds =
  match Ptime.of_float_s seconds with
  | None -> Error seconds
  | Some timestamp -> Ok (Ptime.to_rfc3339 ~frac_s:0 ~tz_offset_s:0 timestamp)

let create () = { retained = None }

let get cache ~source ~render =
  let refresh () =
    let body, comments, initial_comment_offset = render () in
    let rows = { body = Array.of_list body; comments = Array.of_list comments; initial_comment_offset } in
    cache.retained <- Some (source, rows);
    rows
  in
  match cache.retained with
  | None ->
      Masc_tui_frame_timing.note_stage ~name:"board.cache.cold";
      refresh ()
  | Some (previous, rows) ->
      let equal =
        Masc_tui_frame_timing.time_stage_tagged
          ~name:(fun equal ->
            if equal then "board.cache.compare.hit"
            else "board.cache.compare.miss")
          (fun () -> previous = source)
      in
      if equal then rows else refresh ()

let body_line_count rows = Array.length rows.body
let comment_line_count rows = Array.length rows.comments
let body_line rows index = rows.body.(index)
let comment_line rows ~gutter index =
  match rows.comments.(index) with
  | Thread_note text -> text
  | Comment_text { comment_id; text } -> gutter comment_id ^ text

let comment_span rows ~comment_id =
  let owned_by_comment = function
    | Comment_text owned -> String.equal owned.comment_id comment_id
    | Thread_note _ -> false
  in
  let count = Array.length rows.comments in
  let rec first index =
    if index >= count then None
    else if owned_by_comment rows.comments.(index) then Some index
    else first (index + 1)
  in
  let rec past_last index =
    if index < count && owned_by_comment rows.comments.(index) then
      past_last (index + 1)
    else index
  in
  Option.map
    (fun first_row -> (first_row, past_last first_row - first_row))
    (first 0)

let initial_comment_offset rows ~comment_id =
  match rows.initial_comment_offset with
  | Some (id, offset) when String.equal id comment_id -> Some offset
  | Some _ | None -> None
