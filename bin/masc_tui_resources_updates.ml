(** Resources response transitions and selection on the UI state owner fiber. *)

open Masc_tui_types

let listed state result =
  match result with
  | Ok rows ->
    let rows =
      List.map
        (fun (resource : Masc_tui_mcp.resource) ->
           { resource with
             uri = Masc.Tui_terminal_text.sanitize_terminal_text resource.uri
           ; name = Masc.Tui_terminal_text.sanitize_terminal_text resource.name
           ; title =
               Option.map Masc.Tui_terminal_text.sanitize_terminal_text resource.title
           ; description =
               Option.map
                 Masc.Tui_terminal_text.sanitize_terminal_text
                 resource.description
           ; mime_type =
               Option.map Masc.Tui_terminal_text.sanitize_terminal_text resource.mime_type
           })
        rows
    in
    state.resources_list <- Some rows;
    state.resources_error <- None;
    let open_uri =
      match
        state.resource_pending_uri, state.resource_content_error, state.resource_content
      with
      | Some uri, _, _ -> Some uri
      | None, Some (uri, _), _ -> Some uri
      | None, None, Some (uri, _) -> Some uri
      | None, None, None -> None
    in
    let rec index_of_uri index uri = function
      | [] -> None
      | (resource : Masc_tui_mcp.resource) :: rest ->
        if String.equal resource.uri uri
        then Some index
        else index_of_uri (index + 1) uri rest
    in
    (match Option.bind open_uri (fun uri -> index_of_uri 0 uri rows) with
     | Some cursor -> state.resources_cursor <- cursor
     | None ->
       state.resources_cursor <- max 0 (min state.resources_cursor (List.length rows - 1));
       if Option.is_some open_uri
       then (
         state.resource_pending_uri <- None;
         state.resource_content <- None;
         state.resource_content_error <- None;
         state.resource_scroll <- 0))
  | Error detail -> state.resources_error <- Some detail
;;

let read_done state ~uri result =
  match state.resource_pending_uri with
  | Some pending_uri when String.equal pending_uri uri ->
    state.resource_pending_uri <- None;
    (match result with
     | Ok contents ->
       let sanitize_document text =
         String.split_on_char '\n' text
         |> List.map Masc.Tui_terminal_text.sanitize_terminal_text
         |> String.concat "\n"
       in
       let contents =
         List.map
           (fun (content : Masc_tui_mcp.resource_content) ->
              { Masc_tui_mcp.rc_uri =
                  Option.map Masc.Tui_terminal_text.sanitize_terminal_text content.rc_uri
              ; rc_mime_type =
                  Option.map
                    Masc.Tui_terminal_text.sanitize_terminal_text
                    content.rc_mime_type
              ; rc_kind =
                  (match content.rc_kind with
                   | Masc_tui_mcp.Resource_text text ->
                     Masc_tui_mcp.Resource_text (sanitize_document text)
                   | Masc_tui_mcp.Resource_blob _ as blob -> blob)
              })
           contents
       in
       state.resource_content <- Some (uri, contents);
       state.resource_content_error <- None
     | Error detail -> state.resource_content_error <- Some (uri, detail))
  | Some _ | None -> ()
;;

let open_selected state ~read =
  match
    Option.bind state.resources_list (fun resources ->
      List.nth_opt resources state.resources_cursor)
  with
  | None -> ()
  | Some resource ->
    state.resource_focus <- Right_pane;
    read ~uri:resource.Masc_tui_mcp.uri
;;
