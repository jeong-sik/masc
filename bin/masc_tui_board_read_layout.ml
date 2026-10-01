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

type rows = { body : string array; comments : string array; initial_comment_offset : (string * int) option }
type t = { mutable retained : (source * rows) option }
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
let comment_line rows index = rows.comments.(index)

let initial_comment_offset rows ~comment_id =
  match rows.initial_comment_offset with
  | Some (id, offset) when String.equal id comment_id -> Some offset
  | Some _ | None -> None
