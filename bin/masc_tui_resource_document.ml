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
  revisions : Catalog.report list;
}

let entry reading = reading.entry

let current (state : state) =
  let entries = match state.resources_list with Some rows -> rows | None -> [] in
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
       revisions=state.resource_revision_history})
      (Catalog.entry_for_key entries key))

let fenced_pretty_json text =
  let pretty =
    match Yojson.Safe.from_string text with
    | json -> Yojson.Safe.pretty_to_string json
    | exception Yojson.Json_error _ -> text
  in
  Masc_tui_markdown_theme.fenced ~language:"json" pretty

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
  else if String.equal mime "text/html" then Some "html"
  else None

let resource_mime_is_markdown mime =
  List.mem (resource_mime_essence mime)
    [ "text/markdown"; "text/x-markdown"; "application/markdown" ]

let pretty_resource_text ~mime text =
  match resource_language_of_mime mime with
  | Some "json" -> fenced_pretty_json text
  | Some language -> Masc_tui_markdown_theme.fenced ~language text
  | None when resource_mime_is_markdown mime -> text
  | None -> text

let resource_document entry
    (contents : Masc_tui_mcp.resource_content list option) ~error ~requested ~image_cursor ~revisions =
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
  let metadata =
    String.concat "\n\n"
      ([ Catalog.origin entry
      ; "**About:** " ^ present resource.description
      ; "**URI:** `" ^ resource.uri ^ "`"
      ; "**Name:** " ^ resource.name
      ; "**Type:** `" ^ mime ^ "` · **Size:** " ^ size
      ] @ revision_note)
  in
  let part_document index (part : Masc_tui_mcp.resource_content) =
    let part_mime = Option.value part.rc_mime_type ~default:mime in
    let body =
      match part.rc_kind with
      | Masc_tui_mcp.Resource_text text ->
          pretty_resource_text ~mime:part_mime text
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
        let images = Masc_tui_resource_images.images ~mime_type:resource.mime_type parts in
        let selection = match List.nth_opt images image_cursor with
          | Some (part, _) -> Printf.sprintf "Image %d/%d · part %d · ,/.: select · Ctrl-O: preview\n\n"
              (image_cursor + 1) (List.length images) part
          | None -> "" in
        selection ^ (parts |> List.mapi (fun index part -> part_document (index + 1) part)
        |> String.concat "\n\n")
  in
  metadata ^ "\n\n---\n\n" ^ body

let rows ~cols reading =
  let pane_cols = if cols >= Masc_tui_roster_pane.threshold_cols
    then cols - Masc_tui_roster_pane.pane_cols else cols in
  Message_layout.wrap_body ~markdown:Masc_tui_markdown_theme.document
    ~max_cells:(max 1 (framed_inner_width pane_cols - 4))
    ~sanitize:Terminal_text.single_line
    (resource_document reading.entry reading.contents ~error:reading.error
       ~requested:reading.requested ~image_cursor:reading.image_cursor
       ~revisions:reading.revisions)

let search_rows ~cols state =
  match current state with
  | Some ({contents=Some _;error=None;_} as reading) ->
      Some (List.map Masc_tui_theme.strip_sgr (rows ~cols reading))
  | Some {contents=(Some _|None);error=(Some _|None);_} | None -> None
