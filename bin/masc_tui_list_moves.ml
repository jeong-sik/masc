open Masc_tui_types

type row_list = {
  rl_count : int;
  rl_cursor : int;
  rl_place : int -> unit;
}

let over_rows (rows : row_list) move =
  if rows.rl_count > 0 then
    rows.rl_place (Masc_tui_scroll.cursor_apply ~count:rows.rl_count move rows.rl_cursor)

(* Named rather than caught, like the dispatcher's [row_list]: a surface that
   walks something other than its rows is added here once, and a [_] would
   send it to its rows without a word. *)
let moves (state : state) ~rows =
  if state.context_inspector_open || state.repository_changes_open then
    Option.map over_rows (rows ())
  else
    match state.view with
    | Keepers Keeper_list -> Some (move_keeper_list_stop state)
    | Overview -> Some (Masc_tui_home.home_move state)
    | Keepers (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
    | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning | Schedules
    | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
    | Config | Resources | Tools | System_logs ->
        Option.map over_rows (rows ())
