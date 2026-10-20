(** Draw MCP resources from their loaded inventory and content. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows
module Catalog = Masc_tui_resource_catalog

let render_resources (state : state) =
  let drawn_resource_scroll = ref state.resource_scroll in
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = cols >= keeper_split_threshold_cols in
  pane_surface_header buf cols state ~name:"System / Resources" ~split;
  let pane_rows = pane_surface_content_height ~rows in
  let list_rows_budget = pane_rows in
  let rows_list =
    match state.resources_list with Some rows -> rows | None -> []
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
       ^ "Resources"
       ^ (if total = 0 then "" else Printf.sprintf " (%d)" total)
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* The status line spends one of the budgeted rows, not an extra one:
       an extra row pushed the pane past its height and the frame's last
       casualty was the footer. *)
    let status_rows =
      match state.resources_error with
      | Some detail ->
          framed_line pane_buf pane_cols
            ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset);
          1
      | None ->
          (match resources_empty_note state.resources_list with
           | Some note ->
               framed_line pane_buf pane_cols (Ansi.dim ^ note ^ Ansi.reset);
               1
           | None -> 0)
    in
    let list_rows_budget = max 0 (list_rows_budget - status_rows) in
    let first =
      if cursor < list_rows_budget then 0 else cursor - list_rows_budget + 1
    in
    let rows_list_window = Rows.of_list ~first:first ~height:list_rows_budget rows_list in
    for i = 0 to list_rows_budget - 1 do
      match Rows.at rows_list_window (first + i) with
      | Some resource ->
          let selected = first + i = cursor in
          let name = Terminal_text.single_line (Catalog.display_name resource) in
          let line =
            if selected then
              Theme.selection ^ " " ^ name
              ^ String.make
                  (max 0
                     (framed_inner_width pane_cols - 1 - Message_layout.display_width name))
                  ' '
              ^ Ansi.reset
            else " " ^ name
          in
          framed_line pane_buf pane_cols line
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
         let rendered = Masc_tui_resource_document.rows ~cols reading in
         let total_lines = List.length rendered in
         let max_scroll = max 0 (total_lines - content_height) in
         let scroll = max 0 (min state.resource_scroll max_scroll) in
         let rendered_window = Rows.of_list ~first:scroll ~height:content_height rendered in
         (* The pane is the only place that knows how many rows the text
            actually used, so it reports the row it could draw back out. *)
         drawn_resource_scroll := scroll;
         for i = 0 to content_height - 1 do
           match Rows.at rendered_window (scroll + i) with
           | Some line -> box_line pane_buf pane_cols ("  " ^ line)
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
