open Masc_tui_core

let max_entries = 200

type t = {
  entries : Health.incident list;
  next_id : int;
  selected_index : int;
  scroll_offset : int;
  filter_query : string;
  show_dismissed : bool;
  unread_count : int;
}

let empty =
  {
    entries = [];
    next_id = 1;
    selected_index = 0;
    scroll_offset = 0;
    filter_query = "";
    show_dismissed = false;
    unread_count = 0;
  }

let contains_ci ~needle haystack =
  let n_len = String.length needle in
  if n_len = 0 then true
  else
    let h_len = String.length haystack in
    if n_len > h_len then false
    else
      let n_low = String.lowercase_ascii needle in
      let h_low = String.lowercase_ascii haystack in
      let limit = h_len - n_len in
      let rec scan i =
        if i > limit then false
        else if String.equal (String.sub h_low i n_len) n_low then true
        else scan (i + 1)
      in
      scan 0

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

let clamp_index len idx =
  if len <= 0 then 0
  else if idx < 0 then 0
  else if idx >= len then len - 1
  else idx

let push ~occurred_at_unix ~source ~summary ~detail ~status t =
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
  let vis_len = List.length (visible_entries next) in
  let selected_index = clamp_index vis_len next.selected_index in
  ({ next with selected_index }, incident)

let dismiss ~id t =
  let entries =
    List.map
      (fun (inc : Health.incident) ->
        if Int.equal inc.id id then { inc with status = Health.Dismissed }
        else inc)
      t.entries
  in
  let next = { t with entries } in
  let vis_len = List.length (visible_entries next) in
  { next with selected_index = clamp_index vis_len next.selected_index }

let selected_entry t =
  let vis = visible_entries t in
  List.nth_opt vis (clamp_index (List.length vis) t.selected_index)

let dismiss_selected t =
  match selected_entry t with
  | None -> t
  | Some inc -> dismiss ~id:inc.id t

let clear_all t =
  {
    t with
    entries = [];
    selected_index = 0;
    scroll_offset = 0;
    unread_count = 0;
  }

let mark_all_read t = { t with unread_count = 0 }

let find_by_id id t =
  List.find_opt (fun (inc : Health.incident) -> Int.equal inc.id id) t.entries

let default_viewport_rows = 15

let adjust_scroll ?(viewport_rows = default_viewport_rows) ~scroll selected =
  let vr = max 1 viewport_rows in
  if selected < scroll then selected
  else if selected >= scroll + vr then max 0 (selected - vr + 1)
  else scroll

let move_selection ?viewport_rows ~delta t =
  let vis_len = List.length (visible_entries t) in
  let selected_index = clamp_index vis_len (t.selected_index + delta) in
  let scroll_offset =
    adjust_scroll ?viewport_rows ~scroll:t.scroll_offset selected_index
  in
  { t with selected_index; scroll_offset }

let set_filter filter_query t =
  let next = { t with filter_query; selected_index = 0; scroll_offset = 0 } in
  let vis_len = List.length (visible_entries next) in
  { next with selected_index = clamp_index vis_len next.selected_index }

let toggle_show_dismissed t =
  let next = { t with show_dismissed = not t.show_dismissed } in
  let vis_len = List.length (visible_entries next) in
  { next with selected_index = clamp_index vis_len next.selected_index }

let count t = List.length t.entries

let active_count t =
  List.fold_left
    (fun acc (inc : Health.incident) ->
      match inc.status with
      | Health.Dismissed -> acc
      | Health.Resolved | Health.Retried | Health.Superseded -> acc + 1)
    0 t.entries
