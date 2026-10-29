open Masc_tui_types
open Masc_tui_ansi
module Message_layout = Masc_tui_message_layout
module Catalog = Masc_tui_resource_catalog

module Reading = Masc_tui_resource_reading
open Reading
type t = Reading.t

let entry (reading : t) = reading.entry

let recovery_preview_lead ~requested = Printf.sprintf
  "**%s all revisions**\n\n**! retries the original request; it may apply.**"
  (if requested then "ENABLE" else "REVOKE")

let current (state : state) =
  let entries = match visible_resources state with Some rows -> rows | None -> [] in
  let cursor = max 0 (min state.resources_cursor (List.length entries - 1)) in
  let selected = List.nth_opt entries cursor in
  let shown_key = match state.resource_pending_key,
      state.resource_content_error, state.resource_content with
    | Some key, _, _ | None, Some (key, _), _ | None, None, Some (key, _) -> Some key
    | None, None, None ->
      (match selected with
       | Some (Catalog.Report report) ->
         (match List.find_opt (fun request ->
           request.share_workspace = state.workspace_authority
           && String.equal request.share_report.id report.id) state.resource_share_pending with
          | Some request -> Some (Catalog.Report_revision request.share_report)
          | None -> Option.map Catalog.key selected)
       | Some (Catalog.Mcp _) -> Option.map Catalog.key selected
       | None -> None) in
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
      let share_uncertain = match entry with
        | Catalog.Report report -> resource_share_uncertain state report
        | Catalog.Mcp _ -> false in
      let has_original_text = match contents with
        | Some [part] ->
          (match part.Masc_tui_mcp.rc_kind with
           | Resource_text _ -> true | Resource_blob _ -> false)
        | Some [] | Some (_ :: _ :: _) | None -> false in
      let public_url = match entry, has_original_text, error, requested, state.resource_shared with
        | Catalog.Report report, true, None, false, Some true
          when server_authority_ready state && not share_uncertain ->
          Some (Masc_tui_resource_export.public_url ~report
            ~base_url:(Env_config_core.masc_http_base_url_opt ()))
        | (Catalog.Mcp _ | Catalog.Report _), (true | false), (Some _ | None),
          (true | false), (Some _ | None) -> None in
      Reading.create ~entry ~contents ~error ~requested
        ~image_cursor:state.resource_image_cursor ~text_cursor:state.resource_text_cursor
        ~revisions:state.resource_revision_history ~presentation:state.resource_presentation
        ~metadata_expanded:state.resource_metadata_expanded
        ~diagrams:(if Option.is_some state.resource_share_recovery_prompt then None else
          match state.resource_diagrams, contents, requested, error,
            state.resource_presentation with
          | Some diagrams, Some parts, false, None, Catalog.Document
              when Masc_tui_resource_diagrams.owns parts diagrams
                && Option.value state.search ~default:state.search_last = "" -> Some diagrams
          | (Some _ | None), (Some _ | None), (true | false), (Some _ | None),
            (Catalog.Document | Source) -> None)
        ~confirmation:(match entry with Catalog.Mcp _ -> None
          | Report report -> Some (resource_check_status state report))
        ~shared:(match entry with Catalog.Mcp _ -> None
          | Report _ ->
            if share_uncertain || requested || Option.is_some error then None
            else state.resource_shared)
        ~share_uncertain
        ~recovery_preview:(match state.resource_share_recovery_prompt with
          | Some prompt when prompt.recovery_workspace = state.workspace_authority
              && Catalog.equal_key prompt.recovery_key key ->
            let request = prompt.recovery_entry.request in
            Some (Printf.sprintf
              "%s\n\nShare version %d · publication v%d\n\nOperation `%s` · SHA-256 `%s`"
              (recovery_preview_lead ~requested:request.requested) request.expected_version
              request.expected_artifact_revision request.operation_id request.expected_artifact_sha256)
          | Some _ | None -> None)
        ~public_url)
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

let export_source state =
  let open Result.Syntax in
  let* _label, _source = copy_source state in
  match admitted_text_parts state with
  | Some (Catalog.Report report, [(_, source)]) ->
      Masc_tui_resource_export.create ~report ~source
  | Some (Catalog.Mcp _, _) -> Error "Select a published report revision"
  | Some (Catalog.Report _, _) | None -> Error "The report has no single admitted original body"

let copy_public_url state =
  let open Result.Syntax in
  let* () = match current state with
    | Some { share_uncertain = true; _ } ->
      Error "External sharing is unconfirmed; U reconciles the recorded operation and may apply it"
    | Some _ | None -> Ok () in
  let* _ = export_source state in
  match state.resource_shared, current state with
  | Some true, Some { public_url = Some result; _ } -> result
  | Some true, (Some _ | None) -> Error "Press R to reread the report before copying its public link"
  | Some false, (Some _ | None) -> Error "External sharing is off; press P to enable it"
  | None, (Some _ | None) -> Error "External sharing is unknown; press R to reread the report"

let external_share_change state =
  let open Result.Syntax in
  if not (server_authority_ready state) then Error "Confirm the workspace before changing external sharing"
  else if state.view <> Resources || state.resource_focus <> Right_pane then
    Error "Focus a published report to change external sharing"
  else match current state, state.resource_shared with
    | Some { entry = Catalog.Report _; share_uncertain = true; _ }, (Some _ | None) ->
      Error "External sharing is unconfirmed; U reconciles the recorded operation and may apply it"
    | Some { entry = Catalog.Report report; _ }, Some true -> Ok (report, false)
    | Some { entry = Catalog.Report report; _ }, Some false ->
      let* _ = export_source state in Ok (report, true)
    | Some { entry = Catalog.Report _; _ }, None ->
      Error "External sharing is unknown; press R to reread the report"
    | (Some { entry = Catalog.Mcp _; _ } | None), (Some _ | None) ->
      Error "Open a published report to change external sharing"

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

let pretty_resource_text ~mime text =
  (* Parse only the source fragment's own line breaks. Doing this after
     fencing or joining parts would pair a final standalone CR with a
     generated LF and erase its control marker. Retained bytes stay original. *)
  let text = Masc_tui_text_block.lines text |> String.concat "\n" in
  match resource_language_of_mime mime with
  | Some "json" -> fenced_pretty_json text
  | Some language -> Masc_tui_markdown_theme.fenced ~language text
  | None when Masc_tui_resource_images.is_markdown mime -> text
  | None -> text

type piece = Markdown_text of string | Html_text of string
type origin = Metadata | Selection | Part_heading of int | Part_body of int
  | Read_status | Progress | Failure of int

let resource_document entry
    (contents : Masc_tui_mcp.resource_content list option) ~error ~requested ~image_cursor ~text_cursor ~revisions ~presentation ~metadata_expanded ~confirmation ~shared ~share_uncertain ~recovery_preview ~public_url =
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
    let body = match part.rc_kind with
      | Masc_tui_mcp.Resource_text text ->
        (match presentation with
         | Catalog.Document when resource_mime_essence part_mime = "text/html" -> Html_text text
         | Catalog.Document -> Markdown_text (pretty_resource_text ~mime:part_mime text)
         | Catalog.Source -> Markdown_text (Masc_tui_markdown_theme.fenced
             ~language:(Option.value (resource_language_of_mime part_mime) ~default:"")
             (Masc_tui_text_block.lines text |> String.concat "\n")))
      | Masc_tui_mcp.Resource_blob {base64} ->
        Markdown_text (Printf.sprintf "%s · `%s` · %d base64 bytes"
          (if Masc_tui_resource_images.is_image part_mime then "Image data" else "Binary data")
          part_mime (String.length base64)) in
    match contents with
    | Some (_ :: _ :: _) ->
      [Part_heading index, Markdown_text (Printf.sprintf "### Part %d · %s" index part_mime); Part_body index, body]
    | Some (_ :: []) | Some [] | None -> [Part_body index, body] in
  let body = match error, contents with
    | Some detail, _ -> [Read_status, Markdown_text detail]
    | None, None when requested -> [Read_status, Markdown_text "(reading resource…)"]
    | None, None -> [Read_status, Markdown_text "(Enter reads the selected resource.)"]
    | None, Some parts ->
      let texts = text_parts parts in
      let text_selection = match selected_text_part texts text_cursor with
        | Some (part, _) -> Printf.sprintf "Text %d/%d · part %d · (/): select · y: copy source"
            (text_cursor + 1) (List.length texts) part
        | None -> "" in
      let images = Masc_tui_resource_images.images ~mime_type:resource.mime_type parts in
      let selection = match List.nth_opt images image_cursor with
        | Some (part, _) -> Printf.sprintf "Image %d/%d · part %d · ,/.: select · Ctrl-O: preview"
            (image_cursor + 1) (List.length images) part
        | None -> "" in
      [Selection, Markdown_text (text_selection ^ "\n\n" ^ selection)]
        @ List.concat (List.mapi (fun index part -> part_document (index + 1) part) parts) in
  let confirmation = match confirmation with
    | None -> ""
    | Some status -> "\n\n**Confirmation:** " ^ Masc_tui_artifact_checks.description status in
  let sharing = match entry, share_uncertain, shared with
    | Catalog.Mcp _, (true | false), (Some _ | None) -> ""
    | Catalog.Report _, true, (Some _ | None) ->
      "\n\n**External sharing:** change unconfirmed; it may still apply. U shows the recorded change before confirmation."
    | Catalog.Report _, false, None -> "\n\n**External sharing:** unknown (R: reread this revision)"
    | Catalog.Report _, false, Some true -> "\n\n**External sharing:** last observed enabled (P: revoke)"
    | Catalog.Report _, false, Some false -> "\n\n**External sharing:** last observed private (P: enable)" in
  let public_link = match public_url with
    | Some (Ok url) -> "\n\n**Public link:** `" ^ url ^ "` · Y: copy (origin not verified)"
    | Some (Error detail) -> "\n\n**Public link unavailable:** " ^ detail
    | None -> "" in
  let recovery = Option.fold ~none:[] ~some:(fun preview -> [Metadata, Markdown_text preview]) recovery_preview in
  recovery @ ((Metadata, Markdown_text (metadata ^ confirmation ^ sharing ^ public_link ^ "\n\n---")) :: body)

type diagram = {
  first_row : int;
  row_count : int;
  columns : int;
  image : Masc_tui_resource_diagrams.image;
}

type block = { origin : origin; source : Masc_tui_markdown.source_block }
type document_layout = { lines : string list; pictures : diagram list; blocks : block list }

let anchored_layout ~cols (reading : t) =
  let width = max 1 (framed_inner_width cols - 4) in
  let diagram_size image diagrams =
    let cw,ch = Masc_tui_resource_diagrams.cell_pixels diagrams in
    let columns = max 1 (min width ((image.Masc_tui_resource_diagrams.width + cw - 1) / cw)) in
    let rows = max 1 (int_of_float (ceil
      (float_of_int image.height *. float_of_int (columns*cw)
       /. float_of_int image.width /. float_of_int ch))) in
    columns,rows in
  let offset = ref 0 and pictures = ref [] and blocks = ref [] in
  let pieces = resource_document reading.entry reading.contents ~error:reading.error
    ~requested:reading.requested ~image_cursor:reading.image_cursor
    ~text_cursor:reading.text_cursor ~revisions:reading.revisions
    ~presentation:reading.presentation ~metadata_expanded:reading.metadata_expanded
    ~confirmation:reading.confirmation ~shared:reading.shared ~share_uncertain:reading.share_uncertain
    ~recovery_preview:reading.recovery_preview
    ~public_url:reading.public_url in
  let pieces = match reading.diagrams with
    | None -> pieces
    | Some diagrams ->
      let completed,total = Masc_tui_resource_diagrams.progress diagrams in
      let progress = if completed < total then
        [Progress, Markdown_text (Printf.sprintf "Preparing diagrams · %d/%d" completed total)] else [] in
      let failures = Masc_tui_resource_diagrams.sources (Masc_tui_resource_diagrams.request diagrams)
        |> List.mapi (fun index source ->
          Option.map (fun detail -> Failure index, Markdown_text ("Diagram preview unavailable: " ^ detail
            ^ " · r: reread and retry · Ctrl-O: preview selected diagram"))
            (Masc_tui_resource_diagrams.failure ~source diagrams))
        |> List.filter_map Fun.id in
      progress @ failures @ pieces in
  let rows = List.concat_map (fun (origin,piece) ->
    let rows = match piece with
    | Markdown_text document ->
      (match reading.diagrams with
       | None -> Message_layout.wrap_body ~markdown:Masc_tui_markdown_theme.document
           ~max_cells:width ~sanitize:Terminal_text.single_line document
       | Some diagrams ->
         let diagram_rows source = Option.map (fun image -> snd (diagram_size image diagrams))
           (Masc_tui_resource_diagrams.image_for_display ~source diagrams) in
         let rendered = Masc_tui_markdown.render_with_blocks
           ~palette:(Masc_tui_markdown_theme.palette ~closing:Ansi.reset)
           ~width ~diagram_rows (String.split_on_char '\n' document
             |> List.map Terminal_text.single_line |> String.concat "\n") in
         List.iter (fun (source : Masc_tui_markdown.source_block) ->
           blocks := {origin; source={source with first_row= !offset + source.first_row}} :: !blocks)
           rendered.source_blocks;
         List.iter (fun (slot : Masc_tui_markdown.diagram_slot) ->
           match Masc_tui_resource_diagrams.image_for_display ~source:slot.source diagrams with
           | Some image ->
               let columns,_ = diagram_size image diagrams in
               pictures := {first_row= !offset + slot.first_row;
                 row_count=slot.row_count;columns;image} :: !pictures
           | None -> ()) rendered.layout_diagrams;
         rendered.layout_rows) @ [""]
    | Html_text source ->
      Masc_tui_artifact_html.project source
      |> Masc_tui_artifact_html_rows.render ~width in
    (* HTML has no Mermaid replacement, but remains a stable part when earlier
       Markdown preparations alter the prefix. Its own rows keep their offset. *)
    (match piece with
     | Html_text _ when rows <> [] ->
         let source : Masc_tui_markdown.source_block =
           {source_offset=0;first_row= !offset;row_count=List.length rows;kind=Source_block} in
         blocks := {origin;source} :: !blocks
     | Html_text _ | Markdown_text _ -> ());
    offset := !offset + List.length rows;
    rows) pieces in
  {lines=rows;pictures=List.rev !pictures;blocks=List.rev !blocks}

let layout ~cols reading =
  let rendered = anchored_layout ~cols reading in
  rendered.lines,rendered.pictures

let rows ~cols reading = fst (layout ~cols reading)

let recovery_preview_fits ~cols ~height ~requested (reading : t) =
  match reading.recovery_preview, reading.diagrams with
  | Some _, None ->
    let width = max 1 (framed_inner_width cols - 4) in
    let preview_rows = Message_layout.wrap_body ~markdown:Masc_tui_markdown_theme.document
      ~max_cells:width ~sanitize:Terminal_text.single_line (recovery_preview_lead ~requested) in
    preview_rows <> [] && List.length preview_rows <= height
  | (Some _ | None), (Some _ | None) -> false

let search_rows ~cols state =
  match current state with
  | Some reading when Reading.searchable reading ->
      Some (List.map Masc_tui_theme.strip_sgr (rows ~cols:(resource_content_cols state ~cols) reading))
  | Some _ | None -> None

let layout_with_search ~cols state (reading : t) =
  let query = Option.value state.search ~default:state.search_last in
  let admitted = state.resource_focus=Right_pane && Reading.searchable reading in
  let landing = if admitted then Reading.landing ~cols ~query reading
      state.resource_search_position else None in
  let rows,pictures = layout ~cols reading in
  let marked = rows |> List.mapi (fun index text ->
    let mark =
      if admitted && query<>"" && Masc_tui_pick_list.lowercase_contains ~needle:query
          (Masc_tui_theme.strip_sgr text) then
        if landing=Some index then Masc_tui_detail_reading.Current_match else Match
      else Masc_tui_detail_reading.No_match in
    text, mark) in
  marked,pictures

let rows_with_search ~cols state reading = fst (layout_with_search ~cols state reading)

type within_block = Row of int | Diagram_progress of { row : int; extent : int }
type location = Top | End | Block of origin * int * within_block
type anchor = {
  key : Catalog.key;
  contents : Masc_tui_mcp.resource_content list;
  location : location;
}

let anchor_reading (state : state) =
  if state.view <> Resources || state.resource_focus <> Right_pane
     || Option.value state.search ~default:state.search_last <> "" then None
  else match current state with
    | Some ({contents=Some _;error=None;requested=false;
             presentation=Catalog.Document;diagrams=Some _;_} as reading) -> Some reading
    | Some {presentation=(Catalog.Document | Catalog.Source);_} | None -> None

let capture_anchor ~cols ~height state =
  Option.bind (anchor_reading state) (fun reading ->
    Option.bind reading.contents (fun contents ->
      let rendered = anchored_layout ~cols reading in
      let offset = Masc_tui_scroll.Position.offset ~count:(List.length rendered.lines)
        ~height state.resource_scroll in
      let location =
        if Masc_tui_scroll.Position.is_end state.resource_scroll then Some End
        else if offset = 0 then Some Top
        else
          (* A separator belongs to the preceding source block. Boundaries are
             produced by the canonical walker, never inferred from row text. *)
          let rec preceding previous = function
            | block :: rest when block.source.first_row <= offset -> preceding (Some block) rest
            | _ -> previous in
          Option.map (fun block ->
            let row = offset - block.source.first_row in
            let within = match block.source.kind with
              | Masc_tui_markdown.Source_block -> Row row
              | Diagram_block -> Diagram_progress {row;extent=block.source.row_count} in
            Block (block.origin,block.source.source_offset,within))
            (preceding None rendered.blocks) in
      Option.map (fun location -> {key=Catalog.key reading.entry;contents;location}) location))

let source_position anchor = match anchor.location with
  | Block (Part_body part,source_start,_) -> Some (part,source_start)
  | Top | End | Block ((Metadata | Selection | Part_heading _ | Read_status | Progress | Failure _),_,_) -> None

let restore_anchor ~cols ~height state anchor =
  match anchor_reading state with
  | Some reading when Catalog.equal_key (Catalog.key reading.entry) anchor.key
      && (match reading.contents with Some parts -> parts == anchor.contents | None -> false) ->
      let rendered = anchored_layout ~cols reading in
      let position = match anchor.location with
        | Top -> Some Masc_tui_scroll.Position.first
        | End -> Some (Masc_tui_scroll.Position.move ~count:(List.length rendered.lines)
            ~height Last state.resource_scroll)
        | Block (origin,source_start,within) ->
            let block = List.find_opt (fun block -> block.origin=origin
              && block.source.source_offset=source_start) rendered.blocks in
            (* Preparation chrome can disappear entirely. Its semantic successor
               is metadata, regardless of how many failures were inserted. *)
            let block = match block,origin with
              | None,(Progress | Failure _) ->
                  List.find_opt (fun block -> block.origin=Metadata) rendered.blocks
              | (Some _ | None),(Metadata | Selection | Part_heading _ | Part_body _ | Read_status)
              | Some _,(Progress | Failure _) -> block in
            Option.map (fun block ->
              let last = max 0 (block.source.row_count-1) in
              let row = match within with
                | Row row -> min last row
                | Diagram_progress {row;extent} ->
                    (* Preserve progress through an expanding/replaced block;
                       the first and last rows remain its first and last. *)
                    if extent <= 1 then 0
                    else min last (int_of_float (float_of_int row *. float_of_int last
                      /. float_of_int (extent-1))) in
              Masc_tui_scroll.Position.at (block.source.first_row+row)) block in
      Option.iter (fun position -> state.resource_scroll <-
        Masc_tui_scroll.Position.clamp ~count:(List.length rendered.lines) ~height position) position
  | Some _ | None -> ()

let settle_diagram ~cols ~height state ~request ~source result =
  match state.resource_diagrams with
  | Some diagrams when Masc_tui_resource_diagrams.request diagrams == request ->
      let settled = Masc_tui_resource_diagrams.settle request ~source result diagrams in
      if Masc_tui_resource_diagrams.progress settled <> Masc_tui_resource_diagrams.progress diagrams then begin
        let anchor = capture_anchor ~cols ~height state in
        state.resource_diagrams <- Some settled;
        Option.iter (restore_anchor ~cols ~height state) anchor
      end
  | Some _ | None -> ()
