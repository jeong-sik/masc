(* Wrapped rows for the one browser page on screen. Scrolling changes the
   viewport, not this source, and a check tick that finds the page unchanged
   changes neither.

   Object analysis puts up to 200 nodes and 50,000 characters into the view
   (browser_scene_script.ml's nodeLimit, Browser_scene.read's max_chars).
   Wrapping them ran on every frame, and twice per keystroke: once in the
   scroll handler asking for the row count, once in the frame. Retaining one
   page is what Masc_tui_board_read_layout does for one Board document
   (#34272), for the same reason.

   The source mirrors the branches of browser_lane_page_layout, so it holds
   every input that decides a row and nothing else. Comparison is structural,
   but polymorphic compare short-circuits on physical equality, so an
   unchanged node list costs a pointer test rather than a walk. *)

type content =
  | Scene of Masc.Browser_scene.node list
  | Page of string
  | Empty

type source = { content : content; scene_cursor : int; columns : int }
type rows = { lines : string array; selected_row : int option }
type t = { mutable retained : (source * rows) option }

let create () = { retained = None }

let get cache ~source ~render =
  match cache.retained with
  | Some (previous, rows) when previous = source -> rows
  | Some _ | None ->
      let lines, selected_row = render () in
      let rows = { lines = Array.of_list lines; selected_row } in
      cache.retained <- Some (source, rows);
      rows

let count rows = Array.length rows.lines
let line rows index = rows.lines.(index)
let selected_row rows = rows.selected_row
