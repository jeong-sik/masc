open Masc_tui_types
open Masc_tui_ansi
module Message_layout = Masc_tui_message_layout
module Catalog = Masc_tui_resource_catalog

type t = {
  entry : Catalog.t;
  contents : Masc_tui_mcp.resource_content list option;
  error : string option;
  requested : bool;
  image_cursor : int;
  text_cursor : int;
  revisions : Catalog.report list;
  presentation : Catalog.presentation;
  metadata_expanded : bool;
}

let entry reading = reading.entry

let current (state : state) =
  let entries = match visible_resources state with Some rows -> rows | None -> [] in
  let cursor = max 0 (min state.resources_cursor (List.length entries - 1)) in
  let selected = List.nth_opt entries cursor in
  let shown_key = match state.resource_pending_key,
      state.resource_content_error, state.resource_content with
    | Some key, _, _ | None, Some (key, _), _ | None, None, Some (key, _) -> Some key
    | None, None, None -> Option.map Catalog.key selected in
  Option.bind shown_key (fun key ->
    Option.map (fun entry ->
      let contents = match state.resource_content with
        | Some (current, parts) when Catalog.equal_key current key -> Some parts
        | Some _ | None -> None in
      let error = match state.resource_content_error with
        | Some (current, detail) when Catalog.equal_key current key -> Some detail
        | Some _ | None -> None in
      let requested = match state.resource_pending_key with
        | Some current -> Catalog.equal_key current key
        | None -> false in
      {entry;contents;error;requested;image_cursor=state.resource_image_cursor;
       text_cursor=state.resource_text_cursor;
       revisions=state.resource_revision_history;
       presentation=state.resource_presentation;
       metadata_expanded=state.resource_metadata_expanded})
      (Catalog.entry_for_key entries key))

let text_parts parts =
  List.mapi (fun index (part : Masc_tui_mcp.resource_content) ->
    match part.rc_kind with
    | Resource_text source -> Some (index + 1, source)
    | Resource_blob _ -> None) parts
  |> List.filter_map Fun.id

let admitted_text_parts state =
  match state.resource_pending_key, current state with
  | None, Some {entry;contents=Some parts;error=None;_} ->
      Some (entry, text_parts parts)
  | (Some _ | None), (Some _ | None) -> None

let text_part_count state =
  match admitted_text_parts state with
  | Some (_, parts) -> List.length parts
  | None -> 0

let selected_text_part parts cursor =
  if cursor < 0 then None else List.nth_opt parts cursor

let copy_source state =
  if not (server_authority_ready state) then
    Error "Confirm the workspace before copying resource source"
  else if state.view <> Resources || state.resource_focus <> Right_pane then
    Error "Focus resource detail to copy its source"
  else match admitted_text_parts state with
    | None -> Error "Resource source is not currently readable"
    | Some (entry, parts) ->
      match selected_text_part parts state.resource_text_cursor with
      | Some (part, source) ->
          Ok (Printf.sprintf "%s · part %d" (Catalog.display_name entry) part, source)
      | None -> Error "No selected text part in the current resource reading"

let fenced_pretty_json text =
  let pretty =
    match Yojson.Safe.from_string text with
    | json -> Yojson.Safe.pretty_to_string json
    | exception Yojson.Json_error _ -> text
  in
  Masc_tui_markdown_theme.fenced ~language:"json" pretty

(* List and document share one full-width surface by default. Side-by-side
   browsing is an explicit choice; drawing and search use the same pane width. *)

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
  else if String.equal mime "text/html" then Some "html"
  else None

let resource_mime_is_markdown mime =
  List.mem (resource_mime_essence mime)
    [ "text/markdown"; "text/x-markdown"; "application/markdown" ]

let pretty_resource_text ~mime text =
  (* Parse only the source fragment's own line breaks. Doing this after
     fencing or joining parts would pair a final standalone CR with a
     generated LF and erase its control marker. Retained bytes stay original. *)
  let text = Masc_tui_text_block.lines text |> String.concat "\n" in
  match resource_language_of_mime mime with
  | Some "json" -> fenced_pretty_json text
  | Some language -> Masc_tui_markdown_theme.fenced ~language text
  | None when resource_mime_is_markdown mime -> text
  | None -> text

let resource_document entry
    (contents : Masc_tui_mcp.resource_content list option) ~error ~requested ~image_cursor ~text_cursor ~revisions ~presentation ~metadata_expanded =
  let resource = Catalog.metadata entry in
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
  let revision_note = match entry with
    | Catalog.Mcp _ -> []
    | Report report ->
      let available direction = Option.is_some (Catalog.adjacent_revision direction
        ~current:report revisions) in
      [Printf.sprintf "**Revision:** %d · %d known · { older%s · } newer%s"
         report.revision.revision (List.length revisions)
         (if available Catalog.Older then "" else " unavailable")
         (if available Catalog.Newer then "" else " unavailable")] in
  let details =
    String.concat "\n\n"
      ([ Catalog.origin entry
      ; "**About:** " ^ present resource.description
      ; "**URI:** `" ^ resource.uri ^ "`"
      ; "**Name:** " ^ resource.name
      ; "**Type:** `" ^ mime ^ "` · **Size:** " ^ size
      ] @ revision_note)
  in
  let metadata = match entry, metadata_expanded with
    | Catalog.Report report, false ->
      String.concat "\n\n" ([
        Printf.sprintf "**%s · v%d** · %s · %s"
          (match report.revision.format with Masc.Published_artifact.Markdown -> "Markdown" | Html -> "HTML")
          report.revision.revision report.revision.author report.revision.created_at;
        report.revision.summary
      ] @ revision_note)
    | (Catalog.Mcp _ | Catalog.Report _), true | Catalog.Mcp _, false -> details in
  let part_document index (part : Masc_tui_mcp.resource_content) =
    let part_mime = Option.value part.rc_mime_type ~default:mime in
    let body =
      match part.rc_kind with
      | Masc_tui_mcp.Resource_text text ->
          (match presentation with
           | Catalog.Document -> pretty_resource_text ~mime:part_mime text
           | Catalog.Source -> Masc_tui_markdown_theme.fenced
               ~language:(Option.value (resource_language_of_mime part_mime) ~default:"")
               (Masc_tui_text_block.lines text |> String.concat "\n"))
      | Masc_tui_mcp.Resource_blob { base64 } ->
          Printf.sprintf
            "%s · `%s` · %d base64 bytes"
            (if Masc_tui_resource_images.is_image part_mime then "Image data" else "Binary data")
            part_mime (String.length base64)
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
        let texts = text_parts parts in
        let text_selection = match selected_text_part texts text_cursor with
          | Some (part, _) -> Printf.sprintf "Text %d/%d · part %d · (/): select · y: copy source\n\n"
              (text_cursor + 1) (List.length texts) part
          | None -> "" in
        let images = Masc_tui_resource_images.images ~mime_type:resource.mime_type parts in
        let selection = match List.nth_opt images image_cursor with
          | Some (part, _) -> Printf.sprintf "Image %d/%d · part %d · ,/.: select · Ctrl-O: preview\n\n"
              (image_cursor + 1) (List.length images) part
          | None -> "" in
        text_selection ^ selection ^ (parts |> List.mapi (fun index part -> part_document (index + 1) part)
        |> String.concat "\n\n")
  in
  metadata ^ "\n\n---\n\n" ^ body

let rows ~cols reading =
  let document =
    resource_document reading.entry reading.contents ~error:reading.error
      ~requested:reading.requested ~image_cursor:reading.image_cursor
      ~text_cursor:reading.text_cursor ~revisions:reading.revisions
      ~presentation:reading.presentation ~metadata_expanded:reading.metadata_expanded
  in
  Message_layout.wrap_body ~markdown:Masc_tui_markdown_theme.document
    ~max_cells:(max 1 (framed_inner_width cols - 4))
    ~sanitize:Terminal_text.single_line document

let search_rows ~cols state =
  match current state with
  | Some ({contents=Some _;error=None;_} as reading) ->
      Some (List.map Masc_tui_theme.strip_sgr (rows ~cols:(resource_content_cols state ~cols) reading))
  | Some {contents=(Some _|None);error=(Some _|None);_} | None -> None
