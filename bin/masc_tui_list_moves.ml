open Masc_tui_types

type row_list = {
  rl_count : int;
  rl_cursor : int;
  rl_place : int -> unit;
}

type on_screen = {
  os_height : int;
  os_rows : row_list option;
}

let cursor_move ~height (key : Masc_tui_scroll.key_move) : Masc_tui_scroll.Cursor_move.t =
  let page = Masc_tui_scroll.page_step ~height in
  match key with
  | Masc_tui_scroll.Line_down -> Masc_tui_scroll.Cursor_move.Line_down
  | Masc_tui_scroll.Line_up -> Masc_tui_scroll.Cursor_move.Line_up
  | Masc_tui_scroll.Page_down -> Masc_tui_scroll.Cursor_move.Page_down page
  | Masc_tui_scroll.Page_up -> Masc_tui_scroll.Cursor_move.Page_up page
  | Masc_tui_scroll.To_top -> Masc_tui_scroll.Cursor_move.To_top
  | Masc_tui_scroll.To_end -> Masc_tui_scroll.Cursor_move.To_end

let over_rows (rows : row_list) move =
  if rows.rl_count > 0 then
    rows.rl_place (Masc_tui_scroll.cursor_apply ~count:rows.rl_count move rows.rl_cursor)

(* A key on the list on screen moves [walk] by a page of the rows that list
   drew, and no other height reaches the walk. *)
let keyed walk (list : on_screen) key = walk (cursor_move ~height:list.os_height key)

let its_rows (list : on_screen) = Option.map (fun rows -> keyed (over_rows rows) list) list.os_rows

(* Named rather than caught, like the dispatcher's [row_list]: a surface that
   walks something other than its rows is added here once, and a [_] would
   send it to its rows without a word. *)
let moves (state : state) ~on_screen =
  if state.context_inspector_open || state.repository_changes_open then
    Option.bind (on_screen ()) its_rows
  else
    match state.view with
    | Keepers Keeper_list -> Option.map (keyed (move_keeper_list_stop state)) (on_screen ())
    | Overview -> Option.map (keyed (Masc_tui_home.home_move state)) (on_screen ())
    | Keepers (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
    | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning | Schedules
    | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
    | Config | Resources | Tools | System_logs ->
        Option.bind (on_screen ()) its_rows
