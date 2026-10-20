(** Resources response transitions and selection on the UI state owner fiber. *)

open Masc_tui_types

(* The Resources screen has one status line, [resources_error], and a listing
   the walk cut short must be said there: shown rows that stop mid-listing
   otherwise read as the whole listing, which is the defect the walk fixes.
   A warning is not a failure, so the row count stays. The note does not
   promise a remedy: [r] reloads the surface but walks under the same bound,
   and a server that repeats a cursor may well repeat it again. *)
let truncated_listing_note (stop : Masc_tui_mcp.resources_walk_stop) =
  match stop with
  | `Complete -> None
  | `Page_limit_reached pages ->
    Some
      (Printf.sprintf
         "Resources listing may be incomplete: stopped after %d pages and the \
          server has more."
         pages)
  | `Repeated_cursor _ ->
    Some
      "Resources listing may be incomplete: the server repeated a page cursor."

let listed state result =
  match result with
  | Ok (rows, stop) ->
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
    state.resources_error <- truncated_listing_note stop;
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
       (* These bytes are also image/diagram sources. Only the renderer may
          sanitize a display copy; acquisition retains the original observation. *)
       state.resource_content <- Some (uri, contents);
       state.resource_image_cursor <- 0;
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
