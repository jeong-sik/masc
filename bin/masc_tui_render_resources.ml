(** Draw MCP resources from their loaded inventory and content. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Rows = Masc_tui_rows
module Catalog = Masc_tui_resource_catalog

let type_text = function
  | Catalog.Mcp _ -> "[MCP]"
  | Report report ->
      let name = match report.revision.format with
        | Masc.Published_artifact.Markdown -> "MD"
        | Html -> "HTML" in
      Printf.sprintf "[%s v%d]" name report.revision.revision

let type_style = function
  | Catalog.Mcp _ -> Theme.recede ()
  | Report report ->
      (match report.revision.format with
       | Masc.Published_artifact.Markdown -> Theme.category Theme.Slot_1
       | Html -> Theme.category Theme.Slot_2)

let check_style status =
  match status with
  | Masc_tui_artifact_checks.Known
      (Some {state = Masc.Published_artifact_check.Checked; _}) -> Theme.ok ()
  | Known None
  | Known (Some {state = Masc.Published_artifact_check.Unchecked; _}) -> Theme.warn ()
  | Unknown (Masc_tui_value.Unknown.Read_failed, _) -> Theme.bad ()
  | Unknown (Masc_tui_value.Unknown.(Unread | Unreported), _) | Kept_back _ -> Theme.muted ()

(* A report's display name already spells its format, title and revision, and
   the type column says the format and revision, so the row names it by title. *)
let name_text = function
  | Catalog.Report report -> report.revision.title
  | Mcp _ as resource -> Catalog.display_name resource

(* What a resource says about itself, and how it was made. An MCP resource has
   a description, or its address when it has none, and a media type. A report
   has its summary, and its author, creation time and size. *)
let detail_text = function
  | Catalog.Report report -> report.revision.summary
  | Mcp _ as resource ->
      let metadata = Catalog.metadata resource in
      Option.value metadata.description ~default:metadata.uri

let meta_text ~ko = function
  | Catalog.Report report ->
      Printf.sprintf (if ko then "%s · %s · %d바이트" else "%s · %s · %d bytes")
        report.revision.author report.revision.created_at report.revision.body.bytes
  | Mcp _ as resource ->
      Option.value (Catalog.metadata resource).mime_type
        ~default:(if ko then "유형 미상" else "type unknown")

(* One resource is one row: its type, its name, then, for a published report,
   the revision check and the "today" marker, then what it says about itself
   and how it was made. *)
type list_column = Col_type | Col_name | Col_check | Col_day | Col_detail | Col_meta

(* The widest a name keeps. A longer one folds in the middle. *)
let name_cap_cells = 36

(* The narrowest the description is worth drawing. Below it the row stops at
   the columns that identify the resource and the name takes the room. *)
let detail_floor_cells = 20

(* The narrowest a name is drawn when the row has no room for anything after it. *)
let name_floor_cells = 16

(* The widest the media type or the author reading grows. A longer reading
   folds at its end. *)
let meta_cap_cells = 44

(* The widest the rows spread. Past this the cells of one row sit too far apart
   to read across, so a wider pane leaves the rest of its width empty. *)
let table_cap_cells = 120

(* The widest check reading. Held as a constant of the column rather than
   measured over the visible rows, so the columns after it do not move when
   the window scrolls past a different one. *)
let check_cells = Masc_tui_artifact_checks.widest_label_cells

let day_marker ~ko = if ko then "오늘" else "today"

let single_line_cells text =
  Masc_tui_message_layout.display_width (Terminal_text.single_line text)

(* The width a column needs for [texts], never less than its own name: the
   column names are drawn over the same cells. *)
let widest_cells ~name texts =
  List.fold_left (fun widest text -> max widest (single_line_cells text))
    (Masc_tui_message_layout.display_width name) texts

let list_head ~ko = function
  | Col_type -> if ko then "종류" else "TYPE"
  | Col_name -> if ko then "이름" else "NAME"
  | Col_check -> if ko then "확인" else "CHECK"
  | Col_day -> if ko then "날짜" else "DAY"
  | Col_detail -> if ko then "설명" else "DETAIL"
  | Col_meta -> if ko then "메타" else "META"

type list_layout =
  { layout : list_column Masc_tui_table.layout
  ; flex : list_column  (** The column that takes what the others leave. *)
  ; width : list_column -> int
  ; inner_width : int
  ; dropped : int }

(* The columns a list of resources draws at this width. With room for the
   description after the identifying columns the row is type, name, the check
   and marker of a report, the description and the media or author reading; the
   description takes what the rest leave, and the media or author reading goes
   when the row is too wide. Without room for the description the row stops at
   the identifying columns and the marker, and the name takes the room. The
   check and the marker exist only when some resource is a report or was made
   today. *)
let list_layout ~ko resources ~today ~inner_width =
  let head_cells column =
    Masc_tui_message_layout.display_width (list_head ~ko column) in
  let has_report = List.exists (function Catalog.Report _ -> true | Mcp _ -> false) resources in
  let has_today = List.exists (Catalog.on_day today) resources in
  let inner_width = min inner_width table_cap_cells in
  let type_cells =
    widest_cells ~name:(list_head ~ko Col_type) (List.map type_text resources) in
  let name_cells = min name_cap_cells
    (widest_cells ~name:(list_head ~ko Col_name) (List.map name_text resources)) in
  let meta_cells = min meta_cap_cells
    (widest_cells ~name:(list_head ~ko Col_meta) (List.map (meta_text ~ko) resources)) in
  let check_cells = max check_cells (head_cells Col_check) in
  let day_cells =
    max (Masc_tui_message_layout.display_width (day_marker ~ko)) (head_cells Col_day) in
  let identifying = [Col_type; Col_name] @ (if has_report then [Col_check] else []) in
  let marker = if has_today then [Col_day] else [] in
  let describing_needs =
    type_cells + name_cells + (if has_report then check_cells else 0)
    + (if has_today then day_cells else 0) + detail_floor_cells
    + Masc_tui_table.cell_gap * (List.length identifying + List.length marker) in
  if inner_width >= describing_needs then
    let width = function
      | Col_type -> type_cells
      | Col_name -> name_cells
      | Col_check -> check_cells
      | Col_day -> day_cells
      | Col_detail -> detail_floor_cells
      | Col_meta -> meta_cells in
    let layout = Masc_tui_table.fit ~inner_width ~width ~flex:Col_detail
      ~drop_order:[Col_meta] (identifying @ marker @ [Col_detail; Col_meta]) in
    { layout; flex = Col_detail; width; inner_width; dropped = layout.dropped }
  else
    let width = function
      | Col_type -> type_cells
      | Col_name -> name_floor_cells
      | Col_check -> check_cells
      | Col_day -> day_cells
      | Col_detail | Col_meta -> 0 in
    let layout = Masc_tui_table.fit ~inner_width ~width ~flex:Col_name
      ~drop_order:[Col_day] (identifying @ marker) in
    { layout; flex = Col_name; width; inner_width; dropped = layout.dropped + 2 }

(* One row on the layout: [reading] gives a column's text and style for one
   resource, and [None] draws the column names. *)
let list_cells ~ko ({ layout; flex; width; _ } : list_layout) reading =
  List.map (fun column ->
    let header = list_head ~ko column in
    let fold = match column with
      | Col_name -> Masc_tui_table.Fold_middle
      | Col_type | Col_check | Col_day | Col_detail | Col_meta ->
          Masc_tui_table.Fold_tail in
    let value, style = match reading with
      | None -> "", ""
      | Some read -> read column in
    let cell_width = if column = flex then layout.flex_width else width column in
    Masc_tui_table.cell ~header ~fold ~style ~width:cell_width
      (Terminal_text.single_line value)) layout.shown

let selected_marker = "\xe2\x80\xba "
let unselected_marker = "  "
let marker_cells = String.length unselected_marker

let save_prompt_height state = if Option.is_some state.resource_save_prompt then 3 else 0

(* The inventory's reading, which both panes say from this one answer: the
   list's status line and, with nothing open, the pane beside it. A read that
   answered with no resources is an answer, not a wait -- flattened to [] it
   said "(loading...)" for good on a server that exposes none -- and a list no
   read is pending for is unread, not loading. *)
let inventory_idle state =
  Masc_tui_list_idle.of_inventory ~rows:(visible_resources state)
    ~reason:(resource_inventory_status state)
    ~reading:(Option.is_some state.resources_list_owner)

let no_resources ~ko = if ko then "(리소스 없음)" else "(no resources)"

(* Rows left for resources: the pane's content rows less the save prompt, the
   line that says which day and how many are unchecked, the column names, and
   the status line when there is one. *)
let list_rows state ~rows =
  let status = match inventory_idle state with
    | Masc_tui_list_idle.Rows_ready None -> false
    | List_unread | List_loading | List_failed _ | List_empty _ | Rows_ready (Some _) -> true in
  max 0 (pane_surface_content_height ~rows - save_prompt_height state - 2
    - (if status then 1 else 0))

let document_viewport state ~rows ~cols =
  let pane_cols = if resource_split state ~cols then cols - keeper_roster_pane_cols else cols in
  let count = match Masc_tui_resource_document.current state with
    | None -> 0
    | Some reading -> List.length (Masc_tui_resource_document.rows ~cols:pane_cols reading) in
  count, max 0 (pane_surface_content_height ~rows - save_prompt_height state)

let render_resources (state : state) =
  let drawn_resource_scroll = ref state.resource_scroll in
  let terminal_rows, cols = get_terminal_size () in
  let rows = Masc_tui_types.surface_body_rows state ~terminal_rows in
  let buf = Buffer.create 4096 in
  let split = resource_split state ~cols in
  if not split then box_top buf cols;
  let pane_rows = max 0 (pane_surface_content_height ~rows - save_prompt_height state) in
  let rows_list =
    match visible_resources state with Some rows -> rows | None -> []
  in
  let total = List.length rows_list in
  let cursor = max 0 (min state.resources_cursor (total - 1)) in
  (* The document is laid out once, here, because the focused pane's
     position goes on the title row above both panes. *)
  let document_cols = if split then cols - keeper_roster_pane_cols else cols in
  let document =
    lazy
      (Option.map
         (fun reading ->
           ( reading,
             Masc_tui_resource_document.layout_with_search ~cols:document_cols state
               reading ))
         (Masc_tui_resource_document.current state))
  in
  let document_scroll total_lines =
    Masc_tui_scroll.Position.clamp ~count:total_lines ~height:pane_rows
      state.resource_scroll
  in
  let position =
    match state.resource_focus with
    | Left_pane ->
        if total = 0 then None
        else Some (Masc_tui_value.Position.row ~selected:(Some cursor) ~total)
    | Right_pane -> (
        match Lazy.force document with
        | None -> None
        | Some (_, (rendered, _)) ->
            let total_lines = List.length rendered in
            Masc_tui_value.Position.window
              ~first:
                (Masc_tui_scroll.Position.offset ~count:total_lines ~height:pane_rows
                   (document_scroll total_lines))
              ~shown:pane_rows ~total:total_lines)
  in
  box_line buf cols
    (here_row ~cols state
       ~path:[ ui_text state ~ko:"리소스" ~en:"resources" ]
       ~readings:[] ~position);
  Option.iter (fun prompt ->
    let input = prompt.rsp_path in
    let text = Terminal_text.single_line (Masc_tui_message_input.contents input) in
    let before = Terminal_text.single_line (Masc_tui_message_input.before_cursor input) in
    let visible, cursor = Masc_tui_message_layout.input_window
      ~max_cells:(max 0 (cols - 10)) ~cursor:(String.length before) text in
    let left, right = Masc_tui_message_layout.split_at_cells visible cursor in
    box_line buf cols (ui_text state ~ko:"원본 파일 저장 · " ~en:"Save original · "
      ^ Terminal_text.single_line (resource_save_document_title prompt.rsp_document));
    box_line buf cols
      (ui_text state ~ko:"경로: " ~en:"Path: "
       ^ left ^ Ansi.reverse ^ " " ^ Ansi.reset ^ right);
    let notice = match prompt.rsp_error with
      | Some detail -> Theme.warn () ^ Terminal_text.single_line detail ^ Ansi.reset
      | None ->
        (match resource_save_prompt_receipt state prompt with
         | Some receipt -> resource_save_summary state receipt.save_phase
         | None when resource_save_pending_for_prompt state prompt ->
             ui_text state ~ko:"기존 저장 요청 진행 중 · 결과는 본문에서 확인"
               ~en:"An earlier save is pending · read its result below"
         | None -> ui_text state ~ko:"경로 입력 중 · 이 입력은 아직 제출하지 않았습니다"
             ~en:"Editing the path · this input has not been submitted") in
    box_line buf cols notice)
    state.resource_save_prompt;
  let list_pane ~framed pane_buf pane_cols =
    (* Same rule as the code surface: beside the content pane the box is the
       pane separator; alone on a narrow terminal it is the redundant outer
       frame every other surface dropped. *)
    let framed_top = if framed then framed_top else fun _ _ -> () in
    let framed_divider = if framed then framed_divider else box_divider in
    let framed_line = if framed then framed_line else box_line in
    let styled_line = if framed then framed_line_styled else box_line_styled in
    let framed_empty = if framed then framed_empty else box_empty in
    let framed_bottom = if framed then framed_bottom else box_bottom in
    framed_top pane_buf pane_cols;
    let list_focused = state.resource_focus = Left_pane in
    framed_line pane_buf pane_cols
      ((if list_focused then Ansi.bold else Ansi.dim)
       ^ (if list_focused then " \xe2\x96\xb8 " else "   ")
       ^ Catalog.scope_label ~ko:(state.ui_language = Lang_ko) state.resource_scope
       ^ (if total = 0 then "" else Printf.sprintf " (%d)" total)
       ^ Ansi.reset);
    framed_divider pane_buf pane_cols;
    (* The status line spends one of the budgeted rows, not an extra one:
       an extra row pushed the pane past its height and the frame's last
       casualty was the footer. *)
    let ko = state.ui_language = Lang_ko in
    let status_note note = framed_line pane_buf pane_cols (Ansi.dim ^ " " ^ note ^ Ansi.reset) in
    (match inventory_idle state with
     | Masc_tui_list_idle.List_failed detail
     | List_empty (Some detail) | Rows_ready (Some detail) ->
         framed_line pane_buf pane_cols
           ((Theme.bad ()) ^ " " ^ Terminal_text.single_line detail ^ Ansi.reset)
     | List_unread -> status_note (String.trim (page_unread_note ~ko))
     | List_loading -> status_note (if ko then "(읽는 중)" else "(loading)")
     | List_empty None -> status_note (no_resources ~ko)
     | Rows_ready None -> ());

    let period = match state.resource_day with
      | None -> if ko then "모든 날짜" else "all dates"
      | Some day ->
          Masc_tui_value.Local_day.text day ^ (if ko then " (이 장비 시각)" else " local") in
    let today = Catalog.local_day (Unix.gettimeofday ()) in
    let unchecked = match resource_unchecked_today state ~day:today with
      | None -> Theme.muted () ^ (if ko then "모름" else "unknown")
      | Some 0 -> Theme.ok () ^ "0"
      | Some count -> Theme.warn () ^ string_of_int count in
    let query = match Masc_tui_fetched.current state.artifact_checks with
      | Some (_, (Ready inventory | Stale (inventory, _))) ->
        Printf.sprintf
          (if ko then " · 마지막 확인 조회 %s" else " · last check query %s")
          (Masc_tui_value.Instant.detail_text Masc_tui_value.Instant.To_minute ~now:(Unix.gettimeofday ()) inventory.received_at)
      | Some (_, (Absent | Loading | Failed _)) | None ->
          if ko then " · 확인 미조회" else " · checks not read" in
    framed_line pane_buf pane_cols (Theme.recede () ^ " " ^ period
      ^ (if ko then " · 오늘 확인 안 함: " else " · today unchecked: ")
      ^ unchecked ^ Ansi.reset
      ^ Theme.recede () ^ query ^ Ansi.reset);
    let budget = list_rows state ~rows in
    let first = max 0 (cursor - max 1 budget + 1) in
    let table_inner_width = max 1 (framed_inner_width pane_cols - marker_cells) in
    let table = list_layout ~ko rows_list ~today ~inner_width:table_inner_width in
    (* The column names take a row even with nothing to name, so the rows that
       follow start in the same place for an empty list as for a full one. *)
    if total = 0 then framed_empty pane_buf pane_cols
    else
      framed_line pane_buf pane_cols
        (Theme.recede () ^ unselected_marker
         ^ Masc_tui_table.header_row_with_dropped ~ko
             ~inner_width:table.inner_width
             ~dropped:table.dropped
             (list_cells ~ko table None)
         ^ Ansi.reset);
    let visible = Rows.of_list ~first ~height:budget rows_list in
    report_drawn_list Resource_entries ~height:budget;
    for i = 0 to budget - 1 do
      match Rows.at visible (first + i) with
      | Some resource ->
          let selected = first + i = cursor in
          let check = match resource with
            | Catalog.Report report -> Some (resource_check_status state report)
            | Mcp _ -> None in
          let read = function
            | Col_type -> type_text resource, type_style resource
            | Col_name -> name_text resource, Ansi.bold
            | Col_check ->
                (match check with
                 | Some status -> Masc_tui_artifact_checks.label ~ko status, check_style status
                 | None -> "", "")
            | Col_day ->
                (if Catalog.on_day today resource then day_marker ~ko else ""), Theme.recede ()
            | Col_detail -> detail_text resource, Theme.recede ()
            | Col_meta -> meta_text ~ko resource, Theme.recede () in
          let line =
            (if selected then selected_marker else unselected_marker)
            ^ Masc_tui_table.row (list_cells ~ko table (Some read)) in
          (* Keep the selected row's foreground paired with its adaptive
             ground. Content colours are for the neighbouring rows; inner
             resets must not punch holes in the selected band. *)
          if selected then
            styled_line pane_buf pane_cols ~style:(Theme.sidebar_selection ())
              (Masc_tui_theme.strip_sgr line)
          else framed_line pane_buf pane_cols line
      | None -> framed_empty pane_buf pane_cols
    done;
    framed_bottom pane_buf pane_cols
  in
  let content_pane ~split pane_buf pane_cols =
    let reading = Option.map fst (Lazy.force document) in
    let shown_resource = Option.map Masc_tui_resource_document.entry reading in
    let title =
      match shown_resource with
      | Some resource ->
          let share_badge =
            match resource, Option.bind reading (fun r -> r.Masc_tui_resource_reading.shared) with
            | Catalog.Report _, Some true ->
                ui_text state ~ko:" · [마지막 확인: 외부 공유]" ~en:" · [last observed: shared]"
            | Catalog.Report _, Some false ->
                ui_text state ~ko:" · [마지막 확인: 비공개]" ~en:" · [last observed: private]"
            | Catalog.Report _, None | Catalog.Mcp _, _ -> ""
          in
          ui_text state ~ko:"리소스 · " ~en:"Resource · "
          ^ Terminal_text.single_line (Catalog.display_name resource) ^ share_badge
      | None -> ui_text state ~ko:"리소스 상세" ~en:"Resource detail"
    in
    if split then box_top pane_buf pane_cols;
    box_line pane_buf pane_cols
      ((if state.resource_focus = Right_pane then Ansi.bold else Ansi.dim)
       ^ (if state.resource_focus = Right_pane then " \xe2\x96\xb8 " else "   ")
       ^ title
       ^ Ansi.reset);
    box_divider pane_buf pane_cols;
    let content_origin = strip_rows + lines_ended_since pane_buf ~start:0
      + (if pane_buf == buf then 0 else lines_ended_since buf ~start:0) in
    let content_height = pane_rows in
    (match reading with
     | None ->
         let ko = state.ui_language = Lang_ko in
         draw_list_idle pane_buf pane_cols ~ko ~empty:(no_resources ~ko)
           ~height:content_height (inventory_idle state)
     | Some _ ->
         let rendered, pictures =
           match Lazy.force document with
           | Some (_, layout) -> layout
           | None -> [], []
         in
         let total_lines = List.length rendered in
         let position = document_scroll total_lines in
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
                    box_line_selected pane_buf pane_cols ("\xe2\x80\xba " ^ Masc_tui_theme.strip_sgr line)
                | Match -> box_line_styled pane_buf pane_cols ~style:Ansi.underline
                    ("* " ^ Masc_tui_theme.strip_sgr line)
                | No_match -> box_line pane_buf pane_cols ("  " ^ line))
           | None -> box_empty pane_buf pane_cols
         done;
         List.iteri (fun index (picture : Masc_tui_resource_document.diagram) ->
           let image_id = Masc_tui_graphics.resource_image_id index in
           let top = max scroll picture.first_row in
           let bottom = min (scroll+content_height) (picture.first_row+picture.row_count) in
           if top >= bottom then
             Masc_tui_portrait_view.hold_png ~image_id ~key:picture.image.key
           else begin
             let cut = top-picture.first_row in
             let first_px = cut*picture.image.height/picture.row_count in
             let last_px = (bottom-picture.first_row)*picture.image.height/picture.row_count in
             Masc_tui_portrait_view.request_png {
               png_image_id=image_id;
               png_row=content_origin+top-scroll;
               png_column=(if split then keeper_roster_pane_cols else 0)+framed_content_column+2;
               png_cols=picture.columns;png_rows=bottom-top;
               png_crop=Some {top_px=first_px;height_px=max 1 (last_px-first_px)};
               png_key=picture.image.key;png_data=picture.image.png;
             }
           end) pictures);
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
         (match state.resource_save_prompt with
          | Some prompt -> Masc_tui_keys.footer_hints_resource_save
              ~lang:state.ui_language
              ~pending:(resource_save_pending_for_prompt state prompt)
          | None -> Masc_tui_keys.footer_hints_resources
              ~lang:state.ui_language
              ~detail_focus:(state.resource_focus = Right_pane)));
  finish_surface state ~clamped:(Resource_scroll !drawn_resource_scroll)
    ~surface_key:"resources" ~rows:terminal_rows ~cols buf
