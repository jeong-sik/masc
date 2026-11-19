open Masc_tui_types

type row_list = {
  rl_count : int;
  rl_cursor : int;
  rl_place : int -> unit;
}

type page_height =
  | Drawn of paged_list
  | Projected of int

type on_screen = {
  os_page : page_height;
  os_rows : row_list option;
}

let page_height (state : state) = function
  | Drawn list ->
      List.find_map
        (fun (drawn : drawn_list) -> if drawn.dl_list = list then Some drawn.dl_height else None)
        state.lists_drawn
  | Projected height -> Some height

(* With no height there is no page to move by, so a page key moves a row:
   short of a page, it passes no row unseen. *)
let cursor_move ~height (key : Masc_tui_scroll.key_move) : Masc_tui_scroll.Cursor_move.t =
  match key, height with
  | Masc_tui_scroll.Line_down, _ | Masc_tui_scroll.Page_down, None ->
      Masc_tui_scroll.Cursor_move.Line_down
  | Masc_tui_scroll.Line_up, _ | Masc_tui_scroll.Page_up, None ->
      Masc_tui_scroll.Cursor_move.Line_up
  | Masc_tui_scroll.Page_down, Some height ->
      Masc_tui_scroll.Cursor_move.Page_down (Masc_tui_scroll.page_step ~height)
  | Masc_tui_scroll.Page_up, Some height ->
      Masc_tui_scroll.Cursor_move.Page_up (Masc_tui_scroll.page_step ~height)
  | Masc_tui_scroll.To_top, _ -> Masc_tui_scroll.Cursor_move.To_top
  | Masc_tui_scroll.To_end, _ -> Masc_tui_scroll.Cursor_move.To_end

let over_rows (rows : row_list) move =
  if rows.rl_count > 0 then
    rows.rl_place (Masc_tui_scroll.cursor_apply ~count:rows.rl_count move rows.rl_cursor)

(* A key on the list on screen moves [walk] by a page of the rows that list
   drew, and no other height reaches the walk. *)
let keyed state walk (list : on_screen) key =
  walk (cursor_move ~height:(page_height state list.os_page) key)

let its_rows state (list : on_screen) =
  Option.map (fun rows -> keyed state (over_rows rows) list) list.os_rows

(* Named rather than caught, like the dispatcher's [row_list]: a surface that
   walks something other than its rows is added here once, and a [_] would
   send it to its rows without a word. *)
let moves (state : state) ~on_screen =
  if state.context_inspector_open || state.repository_changes_open then
    Option.bind (on_screen ()) (its_rows state)
  else
    match state.view with
    | Keepers Keeper_list -> Option.map (keyed state (move_keeper_list_stop state)) (on_screen ())
    | Overview -> Option.map (keyed state (Masc_tui_home.home_move state)) (on_screen ())
    | Keepers (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
    | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning | Schedules
    | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
    | Config | Resources | Tools | System_logs ->
        Option.bind (on_screen ()) (its_rows state)
