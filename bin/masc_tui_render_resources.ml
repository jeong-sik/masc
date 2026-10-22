(** Draw MCP resources from their loaded inventory and content. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Rows = Masc_tui_rows
module Catalog = Masc_tui_resource_catalog

let entry_rows = 3

let list_viewport state ~rows =
  let status = Option.is_some state.resources_error
    || Option.is_some (resources_empty_note (visible_resources state)) in
  let budget = max 0 (pane_surface_content_height ~rows - 1
    - (if status then 1 else 0)) in
  budget, max 1 (budget / entry_rows)

let list_page_size state ~rows = snd (list_viewport state ~rows)

let document_viewport state ~rows ~cols =
  let pane_cols = if resource_split state ~cols then cols - keeper_roster_pane_cols else cols in
  let count = match Masc_tui_resource_document.current state with
    | None -> 0
    | Some reading -> List.length (Masc_tui_resource_document.rows ~cols:pane_cols reading) in
  count, pane_surface_content_height ~rows

let render_resources (state : state) =
  let drawn_resource_scroll = ref state.resource_scroll in
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = resource_split state ~cols in
  pane_surface_header buf cols state ~name:"Artifacts / Resources" ~split;
  let pane_rows = pane_surface_content_height ~rows in
  let rows_list =
    match visible_resources state with Some rows -> rows | None -> []
  in
  let total = List.length rows_list in
  let cursor = max 0 (min state.resources_cursor (total - 1)) in
  let list_pane ~framed pane_buf pane_cols =
    (* Same rule as the code surface: beside the content pane the box is the
       pane separator; alone on a narrow terminal it is the redundant outer
       frame every other surface dropped. *)
    let framed_top = if framed then framed_top else fun _ _ -> () in
    let framed_divider = if framed then framed_divider else box_divider in
    let framed_line = if framed then framed_line else box_line in
    let framed_empty = if framed then framed_empty else box_empty in
    let framed_bottom = if framed then framed_bottom else box_bottom in
    framed_top pane_buf pane_cols;
    let list_focused = state.resource_focus = Left_pane in
    framed_line pane_buf pane_cols
      ((if list_focused then Ansi.bold else Ansi.dim)
       ^ (if list_focused then " \xe2\x96\xb8 " else " ")
       ^ Catalog.scope_label state.resource_scope
       ^ (if total = 0 then "" else Printf.sprintf " (%d)" total)
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* The status line spends one of the budgeted rows, not an extra one:
       an extra row pushed the pane past its height and the frame's last
       casualty was the footer. *)
    (      match state.resources_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          ()
      | None ->
          (match resources_empty_note (visible_resources state) with
           | Some note ->
               framed_line pane_buf pane_cols (Ansi.dim ^ note ^ Ansi.reset);
               ()
           | None -> ()));

    let period = match state.resource_day with
      | None -> "all dates"
      | Some day -> Printf.sprintf "%04d-%02d-%02d local" day.year day.month day.day in
    let today = Catalog.local_day (Unix.gettimeofday ()) in
    let unchecked = match resource_unchecked_today state ~day:today with
      | None -> "unknown"
      | Some count -> string_of_int count in
    let query = match Masc_tui_fetched.current state.artifact_checks with
      | Some (_, (Ready inventory | Stale (inventory, _))) ->
        let at = Unix.localtime inventory.received_at in
        Printf.sprintf " · last check query %02d:%02d:%02d" at.tm_hour at.tm_min at.tm_sec
      | Some (_, (Absent | Loading | Failed _)) | None -> " · checks not read" in
    framed_line pane_buf pane_cols (Ansi.dim ^ " " ^ period
      ^ " · today unchecked: " ^ unchecked ^ query ^ Ansi.reset);
    let list_rows_budget, visible = list_viewport state ~rows in
    let first = max 0 (cursor - visible + 1) in
    for i = 0 to list_rows_budget - 1 do
      let index = first + i / entry_rows in
      match List.nth_opt rows_list index with
      | Some resource ->
          let selected = index = cursor in
          let metadata = Catalog.metadata resource in
          let line = match i mod entry_rows with
            | 0 -> (if selected then " ▸ " else "   ") ^ Catalog.display_name resource
              ^ (match resource with Catalog.Mcp _ -> ""
                | Report report -> " · " ^ Masc_tui_artifact_checks.label (resource_check_status state report))
              ^ (if Catalog.on_day today resource then " · today" else "")
            | 1 -> "   " ^ (match resource with
                | Catalog.Report report -> report.revision.summary
                | Mcp _ -> Option.value metadata.description ~default:metadata.uri)
            | _ -> "   " ^ (match resource with
                | Catalog.Report report -> Printf.sprintf "%s · %s · %d bytes"
                    report.revision.author report.revision.created_at report.revision.body.bytes
                | Mcp _ -> "MCP · " ^ Option.value metadata.mime_type ~default:"type unknown") in
          let line = Terminal_text.single_line line in
          let color = if selected then Theme.selection
            else if i mod entry_rows = 0 then Ansi.bold else Ansi.dim in
          framed_line pane_buf pane_cols (color ^ line ^ Ansi.reset)
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane ~split pane_buf pane_cols =
    let reading = Masc_tui_resource_document.current state in
    let shown_resource = Option.map Masc_tui_resource_document.entry reading in
    let title =
      match shown_resource with
      | Some resource -> "Resource · " ^ Terminal_text.single_line (Catalog.display_name resource)
      | None -> "Resource detail"
    in
    if split then box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.resource_focus = Right_pane then Ansi.bold else Ansi.dim)
       ^ (if state.resource_focus = Right_pane then " \xe2\x96\xb8 " else " ")
       ^ title
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_height = pane_rows in
    (match reading with
     | None ->
         for _ = 1 to content_height do
           box_empty pane_buf pane_cols
         done
     | Some reading ->
         let rendered = Masc_tui_resource_document.rows_with_search ~cols:pane_cols state reading in
         let total_lines = List.length rendered in
         let position = Masc_tui_scroll.Position.clamp ~count:total_lines
             ~height:content_height state.resource_scroll in
         let scroll = Masc_tui_scroll.Position.offset ~count:total_lines
             ~height:content_height position in
         let rendered_window = Rows.of_list ~first:scroll ~height:content_height rendered in
         (* The pane is the only place that knows how many rows the text
            actually used, so it reports the row it could draw back out. *)
         drawn_resource_scroll := position;
         for i = 0 to content_height - 1 do
           match Rows.at rendered_window (scroll + i) with
           | Some (line, mark) ->
               (match mark with
                | Masc_tui_detail_reading.Current_match ->
                    box_line_selected pane_buf pane_cols ("> " ^ Masc_tui_theme.strip_sgr line)
                | Match -> box_line_styled pane_buf pane_cols ~style:Ansi.underline
                    ("* " ^ Masc_tui_theme.strip_sgr line)
                | No_match -> box_line pane_buf pane_cols ("  " ^ line))
           | None -> box_empty pane_buf pane_cols
         done);
    box_bottom pane_buf pane_cols
  in
  (if split then begin
     let left_cols = keeper_roster_pane_cols in
     let right_cols = cols - left_cols in
     let left_buf = Buffer.create 1024 in
     let right_buf = Buffer.create 4096 in
     list_pane ~framed:true left_buf left_cols;
     content_pane ~split right_buf right_cols;
     write_two_panes buf ~left_cols:left_cols ~left:left_buf
       ~right:right_buf
   end
   else if state.resource_focus = Right_pane then content_pane ~split buf cols
   else list_pane ~framed:false buf cols);
  Buffer.add_string buf
    (footer_line state ~max_cells:cols
       ~hints:
         (Masc_tui_keys.footer_hints_resources
            ~detail_focus:(state.resource_focus = Right_pane)));
  finish_surface state ~clamped:(Resource_scroll !drawn_resource_scroll)
    ~surface_key:"resources" ~rows:terminal_rows ~cols buf
