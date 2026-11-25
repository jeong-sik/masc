open Masc_tui_core

let max_entries = 200

type t = {
  entries : Health.incident list;
  next_id : int;
  selected_index : int;
  scroll_offset : int;
  detail_scroll_offset : int;
  filter_query : string;
  show_dismissed : bool;
  zoomed : bool;
  show_raw_json : bool;
  unread_count : int;
  clear_confirm_armed : bool;
}

let empty =
  {
    entries = [];
    next_id = 1;
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
    filter_query = "";
    show_dismissed = false;
    zoomed = false;
    show_raw_json = false;
    unread_count = 0;
    clear_confirm_armed = false;
  }

let contains_ci = Store_scroll.contains_ci

let source_label = function
  | Health.Source_keeper k -> "keeper:" ^ k
  | Health.Source_runtime r -> "runtime:" ^ r
  | Health.Source_sandbox s -> "sandbox:" ^ s
  | Health.Source_client_http -> "http"
  | Health.Source_stream -> "stream"

let matches_filter query (inc : Health.incident) =
  let q = String.trim query in
  if String.equal q "" then true
  else
    contains_ci ~needle:q inc.detail
    || contains_ci ~needle:q inc.summary.en
    || contains_ci ~needle:q inc.summary.ko
    || contains_ci ~needle:q (source_label inc.source)

let visible_entries t =
  List.filter
    (fun (inc : Health.incident) ->
      let status_ok =
        t.show_dismissed
        || not (Health.equal_incident_status inc.status Health.Dismissed)
      in
      status_ok && matches_filter t.filter_query inc)
    t.entries

let clamp_index = Store_scroll.clamp_index

let push ~occurred_at_unix ~source ~summary ~detail ~status t =
  let prev_zoomed_id =
    if t.zoomed then
      match List.nth_opt (visible_entries t) t.selected_index with
      | Some (inc : Health.incident) -> Some inc.id
      | None -> None
    else None
  in
  let incident : Health.incident =
    { id = t.next_id; occurred_at_unix; source; summary; detail; status }
  in
  let entries = List.take max_entries (incident :: t.entries) in
  let unread_delta =
    match status with
    | Health.Dismissed -> 0
    | Health.Resolved | Health.Retried | Health.Superseded -> 1
  in
  let next_id = if t.next_id = Int.max_int then 1 else t.next_id + 1 in
  let next =
    {
      t with
      entries;
      next_id;
      unread_count = min max_entries (t.unread_count + unread_delta);
    }
  in
  let vis = visible_entries next in
  let vis_len = List.length vis in
  let rec find_id target idx = function
    | [] -> None
    | (inc : Health.incident) :: rest ->
        if Int.equal inc.id target then Some idx else find_id target (idx + 1) rest
  in
  let selected_index, detail_scroll_offset =
    match prev_zoomed_id with
    | Some target -> (
        match find_id target 0 vis with
        | Some idx -> (idx, next.detail_scroll_offset)
        | None -> (clamp_index vis_len next.selected_index, 0))
    | None -> (clamp_index vis_len next.selected_index, next.detail_scroll_offset)
  in
  ({ next with selected_index; detail_scroll_offset }, incident)

let dismiss ~id t =
  let entries =
    List.map
      (fun (inc : Health.incident) ->
        if Int.equal inc.id id then { inc with status = Health.Dismissed }
        else inc)
      t.entries
  in
  let next = { t with entries; clear_confirm_armed = false } in
  let vis_len = List.length (visible_entries next) in
  {
    next with
    selected_index = clamp_index vis_len next.selected_index;
    zoomed = (if vis_len = 0 then false else next.zoomed);
    show_raw_json = (if vis_len = 0 then false else next.show_raw_json);
    detail_scroll_offset = 0;
  }

let selected_entry t =
  let vis = visible_entries t in
  List.nth_opt vis (clamp_index (List.length vis) t.selected_index)

let dismiss_selected t =
  match selected_entry t with
  | None -> { t with clear_confirm_armed = false }
  | Some inc -> dismiss ~id:inc.id t

let clear_all t =
  {
    t with
    entries = [];
    selected_index = 0;
    scroll_offset = 0;
    detail_scroll_offset = 0;
    zoomed = false;
    show_raw_json = false;
    unread_count = 0;
    clear_confirm_armed = false;
  }

let arm_clear_confirm t = { t with clear_confirm_armed = true }
let disarm_clear_confirm t = { t with clear_confirm_armed = false }

let mark_all_read t = { t with unread_count = 0; clear_confirm_armed = false }

let find_by_id id t =
  List.find_opt (fun (inc : Health.incident) -> Int.equal inc.id id) t.entries

let adjust_scroll = Store_scroll.adjust_scroll

let move_selection ?viewport_rows ~delta t =
  let vis_len = List.length (visible_entries t) in
  let selected_index = clamp_index vis_len (t.selected_index + delta) in
  let scroll_offset =
    adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
  in
  let detail_scroll_offset =
    if Int.equal selected_index t.selected_index then t.detail_scroll_offset
    else 0
  in
  {
    t with
    selected_index;
    scroll_offset;
    detail_scroll_offset;
    clear_confirm_armed = false;
  }

let move_detail_scroll ~max_scroll ~delta t =
  let detail_scroll_offset =
    Store_scroll.clamp_scroll ~max_scroll (t.detail_scroll_offset + delta)
  in
  { t with detail_scroll_offset; clear_confirm_armed = false }

let set_filter filter_query t =
  let next =
    {
      t with
      filter_query;
      selected_index = 0;
      scroll_offset = 0;
      detail_scroll_offset = 0;
      zoomed = false;
      show_raw_json = false;
      clear_confirm_armed = false;
    }
  in
  let vis_len = List.length (visible_entries next) in
  { next with selected_index = clamp_index vis_len next.selected_index }

let toggle_show_dismissed t =
  let next =
    {
      t with
      show_dismissed = not t.show_dismissed;
      detail_scroll_offset = 0;
      clear_confirm_armed = false;
    }
  in
  let vis_len = List.length (visible_entries next) in
  { next with selected_index = clamp_index vis_len next.selected_index }

let set_zoomed zoomed t =
  if zoomed then
    { t with zoomed = true; detail_scroll_offset = 0; clear_confirm_armed = false }
  else
    {
      t with
      zoomed = false;
      show_raw_json = false;
      detail_scroll_offset = 0;
      clear_confirm_armed = false;
    }

let toggle_zoom t = set_zoomed (not t.zoomed) t

let toggle_raw_json t =
  {
    t with
    show_raw_json = not t.show_raw_json;
    detail_scroll_offset = 0;
    clear_confirm_armed = false;
  }

let reset_view t =
  {
    t with
    zoomed = false;
    show_raw_json = false;
    detail_scroll_offset = 0;
    clear_confirm_armed = false;
  }

let count t = List.length t.entries

let active_count t =
  List.fold_left
    (fun acc (inc : Health.incident) ->
      match inc.status with
      | Health.Dismissed -> acc
      | Health.Resolved | Health.Retried | Health.Superseded -> acc + 1)
    0 t.entries
