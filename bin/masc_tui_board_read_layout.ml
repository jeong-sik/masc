type source = {
  post : Masc_tui_types.board_post;
  detail :
    (Masc_tui_types.board_post * Masc_tui_types.board_comment list)
      Masc_tui_board_detail.view;
  related_posts : Masc_tui_types.board_post list;
  keeper_names : string list;
  columns : int;
  styles : string list;
  table_frame : bool;
}

type rows = { body : string array; comments : string array }
type t = { mutable retained : (source * rows) option }
let create () = { retained = None }

let get cache ~source ~render =
  match cache.retained with
  | Some (previous, rows) when previous = source -> rows
  | Some _ | None ->
      let body, comments = render () in
      let rows = { body = Array.of_list body; comments = Array.of_list comments } in
      cache.retained <- Some (source, rows);
      rows

let body_count rows = Array.length rows.body
let comment_count rows = Array.length rows.comments
let body_line rows index = rows.body.(index)
let comment_line rows index = rows.comments.(index)
