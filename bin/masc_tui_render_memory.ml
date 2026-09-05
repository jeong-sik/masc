open Masc_tui_types
open Masc.Tui_decode
open Masc_tui_ansi

module Render_schedule = Masc_tui_render_schedule
module Message_layout = Masc_tui_message_layout
module Terminal_text = Masc_tui_ansi.Terminal_text
module Theme = Masc_tui_ansi.Theme

let keeper_lane_idle_text seconds =
  let seconds = max 0 seconds in
  if seconds < 60 then Printf.sprintf "%ds" seconds
  else if seconds < 3600 then Printf.sprintf "%dm" (seconds / 60)
  else if seconds < 86400 then Printf.sprintf "%dh" (seconds / 3600)
  else Printf.sprintf "%dd" (seconds / 86400)

let memory_fact_age_label ts =
  keeper_lane_idle_text (int_of_float (Unix.gettimeofday () -. ts))

let memory_context_lines (k : memory_keeper_health) =
  let current_line =
    Printf.sprintf "  ordinary snapshot r%d · %s · %s" k.mkh_revision
      (Masc_tui_context_inspector.format_bytes k.mkh_snapshot_bytes)
      (if k.mkh_snapshot_present then "present" else "absent")
  in
  let facts_line =
    Printf.sprintf
      "  facts %d (observed %d / derived %d) · last change +%d / -%d / support-invalidated %d"
      k.mkh_facts k.mkh_observed_facts k.mkh_derived_facts k.mkh_added
      k.mkh_removed k.mkh_support_invalidations
  in
  let librarian_line =
    Printf.sprintf "  librarian lane-busy %d · failures %d"
      k.mkh_librarian_lane_busy k.mkh_librarian_failures
  in
  let source_line =
    Printf.sprintf
      "  source-bound snapshot r%d · facts %d · invalidations %d · %s · %s"
      k.mkh_source_revision k.mkh_source_facts k.mkh_source_invalidations
      (Masc_tui_context_inspector.format_bytes k.mkh_source_snapshot_bytes)
      (if k.mkh_source_snapshot_present then "present" else "absent")
  in
  let vision_line =
    let reasons =
      match k.mkh_vision_ingest_error_reasons with
      | [] -> "none"
      | reasons ->
        String.concat ", "
          (List.map
             (fun (reason, count) -> Printf.sprintf "%s x%d" reason count)
             reasons)
    in
    Printf.sprintf "  vision ingest errors %d · reasons %s"
      k.mkh_vision_ingest_errors reasons
  in
  let alert_lines =
    List.map
      (fun (a : memory_alert) ->
        Printf.sprintf "  [%s] %s \xe2\x80\x94 %s" a.ma_severity a.ma_label
          (Terminal_text.single_line a.ma_message))
      k.mkh_alerts
  in
  let read_error_lines =
    List.filter_map Fun.id
      [ Option.map
          (fun message ->
            "  ordinary read error: " ^ Terminal_text.single_line message)
          k.mkh_read_error
      ; Option.map
          (fun message ->
            "  source-bound read error: " ^ Terminal_text.single_line message)
          k.mkh_source_read_error
      ]
  in
  current_line :: facts_line :: source_line :: librarian_line :: vision_line
  :: (read_error_lines @ alert_lines)

type memory_state =
  | Memory_ordinary
  | Memory_warning
  | Memory_degraded
  | Memory_no_current
  | Memory_source_only
  | Memory_starving
  | Memory_read_error

let memory_state (k : memory_keeper_health) =
  if Option.is_some k.mkh_read_error || Option.is_some k.mkh_source_read_error
  then Memory_read_error
  else if
    (not k.mkh_snapshot_present)
    && k.mkh_librarian_failures > 0
    && not k.mkh_source_snapshot_present
  then Memory_starving
  else if (not k.mkh_snapshot_present) && k.mkh_source_snapshot_present
  then Memory_source_only
  else if not k.mkh_snapshot_present
  then Memory_no_current
  else if k.mkh_librarian_failures > 0
  then Memory_degraded
  else if List.exists (fun alert -> String.equal alert.ma_severity "warn") k.mkh_alerts
  then Memory_warning
  else Memory_ordinary

let memory_state_label = function
  | Memory_ordinary -> "ok"
  | Memory_warning -> "warning"
  | Memory_degraded -> "degraded"
  | Memory_no_current -> "no-current"
  | Memory_source_only -> "source-only"
  | Memory_starving -> "STARVING"
  | Memory_read_error -> "read-error"

let memory_state_cell = function
  | Memory_ordinary -> ""
  | state -> memory_state_label state

let memory_deviation_style (k : memory_keeper_health) =
  let server_error =
    List.exists (fun alert -> String.equal alert.ma_severity "error") k.mkh_alerts
  in
  if server_error then Some (Theme.bad ())
  else
    match memory_state k with
    | Memory_starving -> Some (Theme.bad ())
    | Memory_read_error
    | Memory_no_current
    | Memory_source_only
    | Memory_degraded
    | Memory_warning ->
        Some (Theme.warn ())
    | Memory_ordinary -> None

let memory_row_line columns (k : memory_keeper_health) =
  let em_dash = "\xe2\x80\x94" in
  let ordinary_reading value = if k.mkh_snapshot_present then value () else em_dash in
  let source =
    if Option.is_some k.mkh_source_read_error then "read error"
    else if k.mkh_source_snapshot_present then
      Printf.sprintf "r%d i%d %s" k.mkh_source_revision
        k.mkh_source_invalidations
        (Masc_tui_context_inspector.format_bytes k.mkh_source_snapshot_bytes)
    else em_dash
  in
  let delta =
    match k.mkh_added, k.mkh_removed with
    | 0, 0 -> ""
    | added, 0 -> Printf.sprintf "+%d" added
    | 0, removed -> Printf.sprintf "-%d" removed
    | added, removed -> Printf.sprintf "+%d -%d" added removed
  in
  let deviation = Option.value (memory_deviation_style k) ~default:"" in
  let state_style = deviation in
  let size_style = if k.mkh_snapshot_present then "" else deviation in
  let delta_style = if k.mkh_removed > 0 then Theme.warn () else "" in
  "  "
  ^ Render_schedule.memory_row ~state_style ~size_style ~delta_style columns
      { Render_schedule.mrow_state = memory_state_cell (memory_state k)
      ; mrow_name = k.mkh_keeper_id
      ; mrow_revision = ordinary_reading (fun () -> string_of_int k.mkh_revision)
      ; mrow_facts = ordinary_reading (fun () -> string_of_int k.mkh_facts)
      ; mrow_size =
          ordinary_reading (fun () ->
              Masc_tui_context_inspector.format_bytes k.mkh_snapshot_bytes)
      ; mrow_source = source
      ; mrow_delta = delta
      }

let memory_fact_row_line ~cols (row : memory_fact_row) =
  let inner_width = max 10 (framed_inner_width cols) in
  match row with
  | Memory_row_fact fact ->
      let cat_style =
        match fact.mf_category with
        | "rule" | "rules" -> Theme.warn ()
        | "persona" | "identity" -> Theme.info ()
        | "preference" | "user" -> Theme.ok ()
        | "architecture" | "system" -> Theme.info ()
        | _ -> Theme.recede ()
      in
      let raw_cat = Terminal_text.single_line fact.mf_category in
      let cat_str =
        if Message_layout.display_width raw_cat > 10 then
          Message_layout.take_cells raw_cat 9 ^ "\xe2\x80\xa6"
        else raw_cat
      in
      let pad = String.make (max 0 (10 - Message_layout.display_width cat_str)) ' ' in
      let cat_badge = Printf.sprintf "%s[%s%s]%s" cat_style cat_str pad Ansi.reset in
      let age = memory_fact_age_label fact.mf_last_seen in
      let age_badge = Printf.sprintf "%s%6s%s" (Theme.recede ()) age Ansi.reset in
      let prefix = Printf.sprintf "  %s %s " cat_badge age_badge in
      let prefix_cells = 2 + 12 + 1 + 6 + 1 in
      let claim_budget = max 4 (inner_width - prefix_cells) in
      let claim = Terminal_text.single_line fact.mf_claim in
      let claim_display =
        if Message_layout.display_width claim > claim_budget then
          if claim_budget > 1 then
            Message_layout.take_cells claim (claim_budget - 1) ^ "\xe2\x80\xa6"
          else Message_layout.take_cells claim claim_budget
        else claim
      in
      prefix ^ claim_display
  | Memory_row_source_fact fact ->
      let cat_badge = Printf.sprintf "%s[source    ]%s" (Theme.info ()) Ansi.reset in
      let age = memory_fact_age_label fact.msf_first_seen in
      let age_badge = Printf.sprintf "%s%6s%s" (Theme.recede ()) age Ansi.reset in
      let path_raw = Terminal_text.single_line fact.msf_path in
      let path_width = Message_layout.display_width path_raw in
      let path_str =
        if path_width > 16 then
          "\xe2\x80\xa6" ^ Message_layout.drop_cells path_raw (path_width - 15)
        else path_raw
      in
      let pad = String.make (max 0 (16 - Message_layout.display_width path_str)) ' ' in
      let path_badge = Printf.sprintf "%s%s%s%s" (Theme.info ()) path_str pad Ansi.reset in
      let prefix = Printf.sprintf "  %s %s %s " cat_badge age_badge path_badge in
      let prefix_cells = 2 + 12 + 1 + 6 + 1 + 16 + 1 in
      let claim_budget = max 4 (inner_width - prefix_cells) in
      let claim = Terminal_text.single_line fact.msf_claim in
      let claim_display =
        if Message_layout.display_width claim > claim_budget then
          if claim_budget > 1 then
            Message_layout.take_cells claim (claim_budget - 1) ^ "\xe2\x80\xa6"
          else Message_layout.take_cells claim claim_budget
        else claim
      in
      prefix ^ claim_display
  | Memory_row_invalidation row ->
      let cat_badge = Printf.sprintf "%s[dropped   ]%s" (Theme.bad ()) Ansi.reset in
      let age = memory_fact_age_label row.mi_invalidated_at in
      let age_badge = Printf.sprintf "%s%6s%s" (Theme.recede ()) age Ansi.reset in
      let path_raw = Terminal_text.single_line row.mi_source_path in
      let path_width = Message_layout.display_width path_raw in
      let path_str =
        if path_width > 16 then
          "\xe2\x80\xa6" ^ Message_layout.drop_cells path_raw (path_width - 15)
        else path_raw
      in
      let pad = String.make (max 0 (16 - Message_layout.display_width path_str)) ' ' in
      let path_badge = Printf.sprintf "%s%s%s%s" (Theme.recede ()) path_str pad Ansi.reset in
      let prefix = Printf.sprintf "  %s %s %s " cat_badge age_badge path_badge in
      let prefix_cells = 2 + 12 + 1 + 6 + 1 + 16 + 1 in
      let claim_budget = max 4 (inner_width - prefix_cells) in
      let reason = Terminal_text.single_line row.mi_reason in
      let reason_display =
        if Message_layout.display_width reason > claim_budget then
          if claim_budget > 1 then
            Message_layout.take_cells reason (claim_budget - 1) ^ "\xe2\x80\xa6"
          else Message_layout.take_cells reason claim_budget
        else reason
      in
      prefix ^ reason_display

let memory_fact_detail_lines ~cols (row : memory_fact_row) =
  let inner_width = max 30 (cols - 6) in
  match row with
  | Memory_row_fact fact ->
      let claim_lines =
        Message_layout.split_cells ~max_cells:inner_width (Terminal_text.single_line fact.mf_claim)
        |> List.map (fun line -> "    " ^ line)
      in
      [ Printf.sprintf "  %s%sFact Detail%s" Ansi.bold (Theme.info ()) Ansi.reset ]
      @ claim_lines
      @ [ Printf.sprintf "    %sCategory:%s   %-15s" (Theme.recede ()) Ansi.reset fact.mf_category
        ; Printf.sprintf "    %sOrigin:%s     %-15s %sTimeline:%s   First: %s · Last: %s"
            (Theme.recede ()) Ansi.reset fact.mf_origin
            (Theme.recede ()) Ansi.reset
            (memory_fact_age_label fact.mf_first_seen)
            (memory_fact_age_label fact.mf_last_seen)
        ; Printf.sprintf "    %sMemory ID:%s  %s"
            (Theme.recede ()) Ansi.reset fact.mf_memory_id
        ]
  | Memory_row_source_fact fact ->
      let claim_lines =
        Message_layout.split_cells ~max_cells:inner_width (Terminal_text.single_line fact.msf_claim)
        |> List.map (fun line -> "    " ^ line)
      in
      [ Printf.sprintf "  %s%sSource-Bound Fact Detail%s" Ansi.bold (Theme.info ()) Ansi.reset ]
      @ claim_lines
      @ [ Printf.sprintf "    %sBound Path:%s %s" (Theme.recede ()) Ansi.reset fact.msf_path
        ; Printf.sprintf "    %sFile SHA:%s   %s · %sFirst Seen:%s %s"
            (Theme.recede ()) Ansi.reset fact.msf_sha256
            (Theme.recede ()) Ansi.reset (memory_fact_age_label fact.msf_first_seen)
        ]
  | Memory_row_invalidation row ->
      [ Printf.sprintf "  %s%sDropped / Invalidated Fact%s" Ansi.bold (Theme.bad ()) Ansi.reset
      ; Printf.sprintf "    %sReason:%s     %s" (Theme.recede ()) Ansi.reset row.mi_reason
      ; Printf.sprintf "    %sSource Path:%s %s" (Theme.recede ()) Ansi.reset row.mi_source_path
      ; Printf.sprintf "    %sDropped At:%s  %s ago"
          (Theme.recede ()) Ansi.reset (memory_fact_age_label row.mi_invalidated_at)
      ]

let render_memory_body ~cols ~budget (state : state)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~(push_selected : string -> unit)
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let keepers =
    match state.memory_health with
    | None -> []
    | Some s -> s.mhs_keepers
  in
  let shown = List.length keepers in
  let columns =
    Render_schedule.allocate_memory_columns
      ~inner_width:(max 1 (framed_inner_width cols - 2))
  in
  push_styled ~style:(Theme.recede ())
    ("  " ^ Render_schedule.memory_header_row columns);
  push_divider ();
  (match state.memory_health_error with
   | None -> ()
   | Some detail ->
       push_styled ~style:(Theme.bad ())
         ("  " ^ Terminal_text.single_line detail);
       push_divider ());
  let cursor =
    if shown = 0 then 0 else max 0 (min state.memory_health_cursor (shown - 1))
  in
  let context_lines =
    match List.nth_opt keepers cursor with
    | None -> []
    | Some k -> memory_context_lines k
  in
  let context_rows =
    match context_lines with [] -> 0 | _ -> 1 + List.length context_lines
  in
  let fixed =
    2 + context_rows
    + (if Option.is_some state.memory_health_error then 2 else 0)
  in
  let available = max 1 (budget - fixed) in
  let overflowing = shown > available in
  let content_height = if overflowing then max 1 (available - 1) else available in
  let max_scroll = max 0 (shown - content_height) in
  let scroll = max 0 (min state.memory_health_scroll max_scroll) in
  if shown = 0 then
    let note =
      if Option.is_some state.memory_health_error then
        "  (server error \xe2\x80\x94 waiting for retry)"
      else
        match state.memory_health with
        | None -> "  (waiting for the server)"
        | Some _ -> "  (no keepers with a memory config or snapshot)"
    in
    push_styled ~style:(Theme.recede ()) note
  else begin
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt keepers idx with
      | None -> push_empty ()
      | Some k ->
          if idx = cursor then
            push_selected (Masc_tui_theme.strip_sgr (memory_row_line columns k))
          else push (memory_row_line columns k)
    done;
    if overflowing then
      push_styled ~style:(Theme.recede ())
        (Printf.sprintf "[%d keepers, scroll %d]" shown scroll)
  end;
  (match context_lines with
   | [] -> ()
   | lines ->
       push_divider ();
       List.iter (push_styled ~style:(Theme.recede ())) lines)

let render_memory_facts_body ~cols ~budget (state : state)
    ~(push : string -> unit)
    ~(push_styled : style:string -> string -> unit)
    ~(push_selected : string -> unit)
    ~(push_divider : unit -> unit)
    ~(push_empty : unit -> unit) : unit =
  let rows = memory_fact_rows state in
  let total = List.length rows in
  let cursor = max 0 (min state.memory_facts_cursor (total - 1)) in
  let sort_label = memory_sort_order_label state.memory_facts_sort in
  let stats_line, pills_line =
    match state.memory_facts with
    | None -> ("  (loading facts\xe2\x80\xa6)", "")
    | Some snapshot ->
        let ord_count, ord_facts =
          match snapshot.mfs_ordinary with
          | Memory_store_present store ->
              (List.length store.mos_facts, store.mos_facts)
          | _ -> (0, [])
        in
        let src_count, dropped_count =
          match snapshot.mfs_source with
          | Memory_store_present store ->
              (List.length store.mss_facts, List.length store.mss_invalidations)
          | _ -> (0, 0)
        in
        let grand_total = ord_count + src_count + dropped_count in
        let stats =
          Printf.sprintf
            "  %sTotal:%s %d facts  %s(%d ord · %d src · %d drop)%s · %sSort [s]:%s %s"
            Ansi.bold Ansi.reset grand_total
            (Theme.recede ()) ord_count src_count dropped_count Ansi.reset
            (Theme.recede ()) Ansi.reset sort_label
        in
        let all_categories = memory_fact_categories state in
        let pill_of_filter filt count is_active =
          let marker = if is_active then "\xe2\x97\x8f" else "\xe2\x97\x8b" in
          let style = if is_active then Ansi.bold ^ Theme.info () else Theme.recede () in
          let label = memory_category_filter_label filt in
          Printf.sprintf "%s[%s %s: %d]%s" style marker label count Ansi.reset
        in
        let all_pill =
          pill_of_filter Category_all grand_total
            (state.memory_facts_category = Category_all)
        in
        let cat_pills =
          List.map
            (fun filt ->
              let count =
                match filt with
                | Category_all -> grand_total
                | Category_source -> src_count
                | Category_dropped -> dropped_count
                | Category_ordinary cat ->
                    List.length
                      (List.filter
                         (fun (f : memory_fact) -> f.mf_category = cat)
                         ord_facts)
              in
              let is_active = state.memory_facts_category = filt in
              pill_of_filter filt count is_active)
            all_categories
        in
        let pills = "  Categories [c/C]: " ^ String.concat " " (all_pill :: cat_pills) in
        (stats, pills)
  in
  push stats_line;
  if pills_line <> "" then push pills_line;
  let search_banner =
    if String.length (String.trim state.search_last) > 0 then
      Printf.sprintf "  %sFilter [/]:%s \"%s\" (%d matching facts)  %s[Esc to clear]%s"
        Ansi.bold Ansi.reset (Terminal_text.single_line state.search_last) total
        (Theme.recede ()) Ansi.reset
    else ""
  in
  if search_banner <> "" then push search_banner;
  push_divider ();
  (match state.memory_facts_error with
   | None -> ()
   | Some detail ->
       push_styled ~style:(Theme.bad ())
         ("  " ^ Terminal_text.single_line detail);
       push_divider ());
  (match state.memory_facts with
   | None -> ()
   | Some snapshot ->
       (match snapshot.mfs_ordinary with
        | Memory_store_read_error detail ->
            push_styled ~style:(Theme.bad ())
              ("  ordinary store: " ^ Terminal_text.single_line detail)
        | Memory_store_absent | Memory_store_present _ -> ());
       (match snapshot.mfs_source with
        | Memory_store_read_error detail ->
            push_styled ~style:(Theme.bad ())
              ("  source-bound store: " ^ Terminal_text.single_line detail)
        | Memory_store_absent | Memory_store_present _ -> ()));
  let col_header =
    Printf.sprintf "  %-12s %6s %s" "CATEGORY" "AGE" "CLAIM / BOUND PATH"
  in
  push_styled ~style:(Theme.recede ()) col_header;
  push_divider ();
  let detail_lines =
    match List.nth_opt rows cursor with
    | None -> []
    | Some row -> memory_fact_detail_lines ~cols row
  in
  let detail_rows =
    match detail_lines with [] -> 0 | lines -> 1 + List.length lines
  in
  let store_error_rows =
    match state.memory_facts with
    | None -> 0
    | Some snapshot ->
        (match snapshot.mfs_ordinary with
         | Memory_store_read_error _ -> 1
         | Memory_store_absent | Memory_store_present _ -> 0)
        + (match snapshot.mfs_source with
           | Memory_store_read_error _ -> 1
           | Memory_store_absent | Memory_store_present _ -> 0)
  in
  let top_fixed =
    1
    + (if pills_line <> "" then 1 else 0)
    + (if search_banner <> "" then 1 else 0)
    + 1
    + 1
    + 1
    + detail_rows + store_error_rows
    + (if Option.is_some state.memory_facts_error then 2 else 0)
  in
  let room = max 1 (budget - top_fixed) in
  let overflowing = total > room in
  let content_height = if overflowing then max 1 (room - 1) else room in
  let max_scroll = max 0 (total - content_height) in
  let scroll = max 0 (min state.memory_facts_scroll max_scroll) in
  if total = 0 then
    (let empty =
       match state.memory_facts, state.memory_facts_category with
       | None, _ -> "  (waiting for the server)"
       | Some _, Category_all ->
           if state.search_last <> "" then
             Printf.sprintf "  (no facts matching \"%s\" \xe2\x80\x94 Esc clears filter)"
               state.search_last
           else "  (no facts in either store)"
       | Some _, filt ->
           Printf.sprintf "  (no facts in category %s \xe2\x80\x94 c/C cycles)"
             (memory_category_filter_label filt)
     in
     push_styled ~style:(Theme.recede ()) empty)
  else begin
    for i = 0 to content_height - 1 do
      let idx = i + scroll in
      match List.nth_opt rows idx with
      | None -> push_empty ()
      | Some row ->
          let line = memory_fact_row_line ~cols row in
          if idx = cursor then push_selected (Masc_tui_theme.strip_sgr line)
          else push line
    done;
    if overflowing then
      push_styled ~style:(Theme.recede ())
        (Printf.sprintf "[%d facts, scroll %d]" total scroll)
  end;
  (match detail_lines with
   | [] -> ()
   | lines ->
       push_divider ();
       List.iter push lines)
