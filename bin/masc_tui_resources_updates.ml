(** Resources response transitions on the UI state owner fiber. *)
open Masc_tui_types
module Catalog = Masc_tui_resource_catalog

let listed state result =
  match result with
  | Ok { Catalog.entries = rows; notes } ->
    state.resources_list <- Some rows;
    state.resources_error <- (match notes with [] -> None | _ -> Some (String.concat " · " notes));
    let open_uri = match
        state.resource_pending_key, state.resource_content_error, state.resource_content with
      | Some uri, _, _ -> Some uri
      | None, Some (uri, _), _ -> Some uri
      | None, None, Some (uri, _) -> Some uri
      | None, None, None -> None in
    let rec index_of_uri index uri = function
      | [] -> None
      | resource :: rest ->
        if Catalog.owns_key resource uri then Some index
        else index_of_uri (index + 1) uri rest in
    (match Option.bind open_uri (fun uri -> index_of_uri 0 uri rows) with
     | Some cursor -> state.resources_cursor <- cursor
     | None ->
       state.resources_cursor <- max 0 (min state.resources_cursor (List.length rows - 1));
       if Option.is_some open_uri then begin
         state.resource_pending_key <- None;
         state.resource_read_owner <- None;
         state.resource_revision_history <- [];
         state.resource_content <- None;
         state.resource_content_error <- None;
         state.resource_scroll <- 0
       end)
  | Error detail -> state.resources_error <- Some detail

let read_done state ~(request : Catalog.read_request) result =
  match state.resource_pending_key, state.resource_read_owner with
  | Some pending_key, Some owner when owner == request.owner && Catalog.equal_key pending_key request.key ->
    let key = request.key in
    state.resource_pending_key <- None;
    state.resource_read_owner <- None;
    (match result with
     | Ok (reading : Catalog.reading) ->
       (* Acquisition retains original bytes; only display copies are sanitized. *)
       state.resource_content <- Some (key, reading.parts);
       state.resource_revision_history <- reading.revisions;
       state.resource_image_cursor <- 0;
       state.resource_content_error <- None
     | Error detail -> state.resource_content_error <- Some (key, detail))
  | (Some _ | None), (Some _ | None) -> ()

let open_selected state ~read =
  match Option.bind state.resources_list (fun resources ->
      List.nth_opt resources state.resources_cursor) with
  | None -> ()
  | Some resource ->
    state.resource_focus <- Right_pane;
    read ~key:(Catalog.key resource)

let step_revision state ~direction ~read =
  let current = match state.resource_pending_key, state.resource_content_error, state.resource_content with
    | Some key, _, _ | None, Some (key, _), _ | None, None, Some (key, _) -> Some key
    | None, None, None -> None in
  match current with
  | Some (Catalog.Report_revision report) ->
    Option.iter (fun revision -> read ~key:(Catalog.Report_revision revision))
      (Catalog.adjacent_revision direction ~current:report state.resource_revision_history)
  | Some (Catalog.Mcp_uri _) | None -> ()
