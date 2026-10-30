module Decode = Masc.Tui_decode

type source = Server | This_tui
let source_label = function Server -> "Server" | This_tui -> "This TUI"
type page = {
  lp_snapshot : Decode.system_log_snapshot option;
  lp_error : string option;
  lp_scroll : int;
  lp_cursor : int;
  lp_min_level : Decode.system_log_level option;
  lp_category : string option;
  lp_detail_seq : int option;
  lp_detail_scroll : int;
}
let empty_page = {lp_snapshot=None;lp_error=None;lp_scroll=0;lp_cursor=0;
  lp_min_level=None;lp_category=None;lp_detail_seq=None;lp_detail_scroll=0}
type t = {selected:source;server:page;client:page}
let empty = {selected=Server;server=empty_page;client=empty_page}
let source t = t.selected
let page source t = match source with Server -> t.server | This_tui -> t.client
let current t = page t.selected t
let select selected t = {t with selected}
let update source change t = match source with
  | Server -> {t with server=change t.server}
  | This_tui -> {t with client=change t.client}
let update_current change t = update t.selected change t
let visible page = match page.lp_snapshot with
  | None -> []
  | Some snapshot -> match page.lp_category with
    | None -> snapshot.sys_entries
    | Some wanted -> List.filter (fun entry -> match entry.Decode.sl_category with
      | Some observed -> String.equal wanted observed | None -> false) snapshot.sys_entries
let apply source result t = update source (fun page -> match result with
  | Error detail -> {page with lp_error=Some detail}
  | Ok snapshot ->
    let page={page with lp_snapshot=Some snapshot;lp_error=None} in
    {page with lp_cursor=max 0 (min page.lp_cursor (List.length (visible page)-1))}) t
let clear_server t = update Server (fun page ->
  {empty_page with lp_min_level=page.lp_min_level;lp_category=page.lp_category}) t

let client_snapshot ~limit ~min_level =
  let level=match min_level with
    | None | Some Decode.System_debug -> Ok Log.Debug
    | Some System_info -> Ok Log.Info
    | Some System_warn -> Ok Log.Warn
    | Some System_error -> Ok Log.Error
    | Some (System_level_unknown _) -> Error "Unknown severity cannot select a local log floor" in
  Result.bind level (fun level ->
    let entries=Log.Ring.recent ~limit ~min_level:(Log.level_to_int level) () in
    let latest=match entries with [] -> `Null | entry::_ -> `Int entry.Log.Ring.seq in
    Decode.decode_system_log_snapshot (`Assoc [
      "entries",`List (List.map Log.Ring.entry_to_json entries);
      "total",`Int (Log.Ring.bounds ()).total;
      "latest_seq",latest]))
