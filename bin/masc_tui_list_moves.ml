open Masc_tui_types

type row_list = {
  rl_count : int;
  rl_cursor : int;
  rl_place : int -> unit;
}

type on_screen = {
  os_list : paged_list;
  os_rows : row_list option;
}

let page_height (state : state) list =
  List.find_map
    (fun (drawn : drawn_list) -> if drawn.dl_list = list then Some drawn.dl_height else None)
    state.lists_drawn

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
  walk (cursor_move ~height:(page_height state list.os_list) key)

let its_rows state (list : on_screen) =
  Option.map (fun rows -> keyed state (over_rows rows) list) list.os_rows

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
        match state.tools_skill_focus, tools_skill_profiles state with
        | Choosing_skill, _ :: _ -> Some Tools_skills
        | Choosing_skill, [] | Reading_page, _ -> None)
    | Tools_async when state.tools_async_detail_open -> None
    | Tools_async -> (
        match tools_async_targets state with
        | _ :: _ -> Some Tools_async_requests
        | [] -> None)
    | Tools_usage | Tools_storage
    | Tools_catalog (Tools_catalog_list | Tools_catalog_volumes _) -> None

let read_skill_page (state : state) =
  match state.tools_pane, selected_tools_skill_profile state with
  | Tools_surface, Some _ -> state.tools_skill_focus <- Reading_page
  | Tools_surface, None
  | (Tools_async | Tools_usage | Tools_storage | Tools_catalog _), _ -> ()

let choose_skill_again (state : state) =
  match state.tools_pane, state.tools_skill_focus with
  | Tools_surface, Reading_page ->
      state.tools_skill_focus <- Choosing_skill;
      true
  | Tools_surface, Choosing_skill
  | (Tools_async | Tools_usage | Tools_storage | Tools_catalog _), _ -> false

(* What the footer says j/k and Esc do: read from [tools_list], the focus,
   the original Task and the open request, the facts the move keys and Esc's
   arm read. Esc's arm asks the original Task first, then the open request,
   and so does this. *)
let tools_keys (state : state) : Masc_tui_keys.tools_keys =
  match tools_list state with
  | Some (Tools_skills | Tools_async_requests) -> Masc_tui_keys.Tools_walks_list
  | None -> (
      match state.tools_pane, state.tools_skill_focus with
      | Tools_surface, Reading_page -> Masc_tui_keys.Tools_reads_skill_page
      | Tools_async, _ when Option.is_some state.tools_async_task_source ->
          Masc_tui_keys.Tools_reads_original_task
      | Tools_async, _ when state.tools_async_detail_open ->
          Masc_tui_keys.Tools_reads_request
      | Tools_surface, Choosing_skill
      | (Tools_async | Tools_usage | Tools_storage | Tools_catalog _), _ ->
          Masc_tui_keys.Tools_reads_page)

let show_tools_pane (state : state) pane =
  state.tools_pane <- pane;
  state.tools_skill_focus <- Choosing_skill

let move_tools_skill state move =
  let count = List.length (tools_skill_profiles state) in
  state.tools_skill_cursor <- Masc_tui_scroll.cursor_apply ~count move state.tools_skill_cursor

let move_tools_list state list move =
  match list with
  | Tools_skills -> move_tools_skill state move
  | Tools_async_requests -> move_tools_async_selection state move

(* The name the frame reports each Tools list drawn under
   ([Masc_tui_render_tools.display]'s entries). *)
let tools_drawn_list = function
  | Tools_skills -> Skill_entries
  | Tools_async_requests -> Async_request_entries

(* Named rather than caught, like the dispatcher's [row_list]: a surface that
   walks something other than its rows is added here once, and a [_] would
   send it to its rows without a word. *)
let moves (state : state) ~on_screen ~follow =
  if state.context_inspector_open || state.repository_changes_open then
    Option.bind (on_screen ()) (its_rows state)
  else
    match state.view with
    | Keepers Keeper_list -> Option.map (keyed state (move_keeper_list_stop state)) (on_screen ())
    | Overview -> Option.map (keyed state (Masc_tui_home.home_move state)) (on_screen ())
    (* The Tools selection takes the page its list was drawn in like any
       other list, then hands the landing to [follow]. *)
    | Tools ->
        Option.map (fun list key ->
          move_tools_list state list
            (cursor_move ~height:(page_height state (tools_drawn_list list)) key);
          follow list)
          (tools_list state)
    | Keepers (Keeper_detail | Keeper_logs | Keeper_calls | Keeper_message | Keeper_runtime_pick)
    | Acting | Metrics | Memory | Lanes | Clients | Board | Approvals | Planning | Schedules
    | Verification | Harness | Fusion | Repositories | Code | Changes | Connectors | Runtime
    | Config | Resources | System_logs ->
        Option.bind (on_screen ()) (its_rows state)
