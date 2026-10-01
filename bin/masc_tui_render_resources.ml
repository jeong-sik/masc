(** Draw MCP resources from their loaded inventory and content. *)

open Masc_tui_types
open Masc_tui_ansi
open Masc_tui_render_prim

module Message_layout = Masc_tui_message_layout
module Rows = Masc_tui_rows

let fenced_pretty_json text =
  let pretty =
    match Yojson.Safe.from_string text with
    | json -> Yojson.Safe.pretty_to_string json
    | exception Yojson.Json_error _ -> text
  in
  fenced_document_text ~language:"json" pretty

(* The Resources surface: the MCP resource inventory on the left, the
   selected read on the right. Wide terminals show both; narrow ones show
   the list, and Enter swaps to the content until Esc. *)

let resource_mime_essence mime =
  match String.split_on_char ';' (String.lowercase_ascii (String.trim mime)) with
  | essence :: _ -> String.trim essence
  | [] -> ""

let resource_language_of_mime mime =
  let mime = resource_mime_essence mime in
  if
    String.equal mime "application/json"
    || String.equal mime "text/json"
    || String.ends_with ~suffix:"+json" mime
  then Some "json"
  else if List.mem mime [ "application/toml"; "text/toml"; "text/x-toml" ]
  then Some "toml"
  else if
    List.mem mime
      [ "application/yaml"; "application/x-yaml"; "text/yaml"; "text/x-yaml" ]
  then Some "yaml"
  else None

let resource_mime_is_markdown mime =
  List.mem (resource_mime_essence mime)
    [ "text/markdown"; "text/x-markdown"; "application/markdown" ]

let pretty_resource_text ~mime text =
  match resource_language_of_mime mime with
  | Some "json" -> fenced_pretty_json text
  | Some language -> fenced_document_text ~language text
  | None when resource_mime_is_markdown mime -> text
  | None -> text

let resource_document (resource : Masc_tui_mcp.resource)
    (contents : Masc_tui_mcp.resource_content list option) ~error ~requested =
  let present = function
    | Some text when String.trim text <> "" -> text
    | Some _ | None -> "not supplied"
  in
  let size =
    match resource.size with
    | Some bytes -> Printf.sprintf "%d bytes" bytes
    | None -> "size unknown"
  in
  let mime = present resource.mime_type in
  let metadata =
    String.concat "\n\n"
      [ "MCP resource — read-only data exposed by this server."
      ; "**About:** " ^ present resource.description
      ; "**URI:** `" ^ resource.uri ^ "`"
      ; "**Name:** " ^ resource.name
      ; "**Type:** `" ^ mime ^ "` · **Size:** " ^ size
      ]
  in
  let part_document index (part : Masc_tui_mcp.resource_content) =
    let part_mime = Option.value part.rc_mime_type ~default:mime in
    let body =
      match part.rc_kind with
      | Masc_tui_mcp.Resource_text text ->
          pretty_resource_text ~mime:part_mime text
      | Masc_tui_mcp.Resource_blob { base64_bytes } ->
          Printf.sprintf
            "Binary data · `%s` · %d base64 bytes · preview unavailable"
            part_mime base64_bytes
    in
    match contents with
    | Some (_ :: _ :: _) ->
        Printf.sprintf "### Part %d · %s\n\n%s" index part_mime body
    | Some (_ :: []) | Some [] | None -> body
  in
  let body =
    match (error, contents) with
    | Some detail, _ -> detail
    | None, None when requested -> "(reading resource…)"
    | None, None -> "(Enter reads the selected resource.)"
    | None, Some parts ->
        parts |> List.mapi (fun index part -> part_document (index + 1) part)
        |> String.concat "\n\n"
  in
  metadata ^ "\n\n---\n\n" ^ body

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
          let name = Masc_tui_mcp.display_name resource in
          let line =
            if selected then
              Theme.selection ^ " " ^ name
              ^ String.make
                  (max 0
                     (pane_cols - 5 - Message_layout.display_width name))
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
    let selected_resource = List.nth_opt rows_list cursor in
    let error_uri = Option.map fst state.resource_content_error in
    let content_uri = Option.map fst state.resource_content in
    let shown_uri =
      match state.resource_pending_uri, error_uri, content_uri with
      | Some uri, _, _ -> Some uri
      | None, Some uri, _ -> Some uri
      | None, None, Some uri -> Some uri
      | None, None, None -> Option.map (fun resource -> resource.Masc_tui_mcp.uri) selected_resource
    in
    let shown_resource =
      Option.bind shown_uri (fun uri ->
          List.find_opt
            (fun (resource : Masc_tui_mcp.resource) ->
               String.equal resource.uri uri)
            rows_list)
    in
    let title =
      match shown_resource with
      | Some resource -> "Resource · " ^ Masc_tui_mcp.display_name resource
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
    (match shown_resource with
     | None ->
         for _ = 1 to content_height do
           box_empty pane_buf pane_cols
         done
     | Some resource ->
         let contents =
           match state.resource_content, shown_uri with
           | Some (content_uri, parts), Some uri
             when String.equal content_uri uri -> Some parts
           | Some _, (Some _ | None) | None, _ -> None
         in
         let error =
           match state.resource_content_error, shown_uri with
           | Some (error_uri, detail), Some uri
             when String.equal error_uri uri -> Some detail
           | Some _, (Some _ | None) | None, _ -> None
         in
         let requested =
           match state.resource_pending_uri, shown_uri with
           | Some pending_uri, Some uri -> String.equal pending_uri uri
           | Some _, None | None, _ -> false
         in
         let rendered =
           Message_layout.wrap_body ~markdown:document_markdown
             ~max_cells:(max 1 (pane_cols - 8))
             ~sanitize:Terminal_text.single_line
             (resource_document resource contents ~error ~requested)
         in
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
