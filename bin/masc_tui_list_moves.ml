open Masc_tui_types

type row_list = {
  rl_count : int;
  rl_cursor : int;
  rl_place : int -> unit;
}

let over_rows (rows : row_list) move =
  if rows.rl_count > 0 then
    rows.rl_place (Masc_tui_scroll.cursor_apply ~count:rows.rl_count move rows.rl_cursor)

type tools_list =
  | Tools_skills
  | Tools_async_requests

(* Every pane named: a pane that grows a list is added here once, and a [_]
   would leave its move keys scrolling the page without a word. *)
let tools_list (state : state) =
  if Option.is_some state.tools_skill_source_picker then None
  else
    match state.tools_pane with
    | Tools_surface -> (
        match tools_skill_profiles state with
        | _ :: _ -> Some Tools_skills
        | [] -> None)
    | Tools_async when state.tools_async_detail_open -> None
    | Tools_async -> (
        match tools_async_targets state with
        | _ :: _ -> Some Tools_async_requests
        | [] -> None)
    | Tools_activations | Tools_usage | Tools_storage
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) -> None

let move_tools_skill state move =
  let count = List.length (tools_skill_profiles state) in
  state.tools_skill_cursor <- Masc_tui_scroll.cursor_apply ~count move state.tools_skill_cursor

let move_tools_list state list move =
  match list with
  | Tools_skills -> move_tools_skill state move
  | Tools_async_requests -> move_tools_async_selection state move

(* Named rather than caught, like the dispatcher's [row_list]: a surface that
   walks something other than its rows is added here once, and a [_] would
   send it to its rows without a word. *)
let moves (state : state) ~rows ~follow =
  if state.context_inspector_open || state.repository_changes_open then
    Option.map over_rows (rows ())
  else
    match state.view with
    | Keepers Keeper_list -> Some (move_keeper_list_stop state)
    | Overview -> Some (Masc_tui_home.home_move state)
    | Tools ->
        Option.map (fun list move ->
          move_tools_list state list move;
          follow list)
          (tools_list state)
    | Keepers (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
    | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning | Schedules
    | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
    | Config | Resources | System_logs ->
        Option.map over_rows (rows ())
