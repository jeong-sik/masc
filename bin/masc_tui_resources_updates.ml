(** Resources response transitions on the UI state owner fiber. *)
open Masc_tui_types
module Catalog = Masc_tui_resource_catalog

let reconcile state =
  let rows = Option.value (visible_resources state) ~default:[] in
  let open_key = match state.resource_pending_key,
      state.resource_content_error, state.resource_content with
    | Some key, _, _ | None, Some (key, _), _ | None, None, Some (key, _) -> Some key
    | None, None, None -> None in
  let rec index_of_key index key = function
    | [] -> None
    | entry :: rest -> if Catalog.owns_key entry key then Some index
        else index_of_key (index + 1) key rest in
  match Option.bind open_key (fun key -> index_of_key 0 key rows) with
  | Some cursor -> state.resources_cursor <- cursor
  | None ->
    state.resources_cursor <- max 0 (min state.resources_cursor (List.length rows - 1));
    if Option.is_some open_key then begin
      state.resource_pending_key <- None;
      state.resource_read_owner <- None;
      state.resource_revision_history <- [];
      state.resource_content <- None;
      state.resource_content_error <- None;
      state.resource_scroll <- Masc_tui_scroll.Position.first;
      state.resource_search_position <- Masc_tui_resource_reading.first;
      state.resource_text_cursor <- 0;
      state.resource_image_cursor <- 0;
      state.resource_focus <- Left_pane
    end

let begin_listing state =
  let owner = ref () in
  state.resources_list_owner <- Some owner;
  state.resources_reports_complete <- false;
  owner

let listed state ~owner result =
  match state.resources_list_owner with
  | None -> ()
  | Some current when current != owner -> ()
  | Some _ ->
  state.resources_list_owner <- None;
  match result with
  | Ok { Catalog.entries = rows; notes; reports_complete } ->
    state.resources_list <- Some rows;
    state.resources_reports_complete <- reports_complete;
    state.resources_error <- (match notes with [] -> None | _ -> Some (String.concat " · " notes));
    reconcile state
  | Error detail ->
    state.resources_reports_complete <- false;
    state.resources_error <- Some detail

let checks_loaded state request result =
  state.artifact_checks <- Masc_tui_fetched.complete ~equal:Unit.equal
    state.artifact_checks request result

let begin_check state ~report =
  if not (server_authority_ready state) then Error "Workspace identity is unconfirmed"
  else match state.artifact_check_pending with
  | Some _ -> Error "A confirmation change is still pending"
  | None ->
    let ( let* ) = Result.bind in
    let* request = Masc_tui_artifact_check_action.prepare state.artifact_checks report in
    state.artifact_check_pending <- Some request;
    state.artifact_checks <- Masc_tui_fetched.clear state.artifact_checks;
    Ok request

let check_changed state request = match state.artifact_check_pending with
  | Some current when Masc_tui_artifact_check_action.same_request current request ->
    state.artifact_check_pending <- None;
    state.artifact_checks <- Masc_tui_fetched.clear state.artifact_checks;
    true
  | Some _ | None -> false

let select_scope state scope =
  state.resource_scope <- scope;
  state.resources_cursor <- 0;
  state.search <- None;
  state.search_last <- "";
  reconcile state

let toggle_today state ~now =
  state.resource_day <- (match state.resource_day with
    | None -> Some (Catalog.local_day now)
    | Some _ -> None);
  select_scope state state.resource_scope

let reset_document_position state =
  state.resource_scroll <- Masc_tui_scroll.Position.first;
  state.resource_search_position <- Masc_tui_resource_reading.first

let toggle_layout state =
  state.resource_layout <- (match state.resource_layout with
    | Catalog.Full_width -> Catalog.Side_by_side
    | Side_by_side -> Full_width);
  reset_document_position state

let toggle_presentation state =
  state.resource_presentation <- (match state.resource_presentation with
    | Catalog.Document -> Catalog.Source | Source -> Document);
  reset_document_position state

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
       state.resource_text_cursor <- 0;
       state.resource_search_position <- Masc_tui_resource_reading.first;
       state.resource_content_error <- None
     | Error detail -> state.resource_content_error <- Some (key, detail))
  | (Some _ | None), (Some _ | None) -> ()

let open_selected state ~read =
  match Option.bind (visible_resources state) (fun resources ->
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

let select_next_unchecked state =
  let ( let* ) = Result.bind in
  let* () =
    if not (server_authority_ready state) then Error "Workspace identity is unconfirmed"
    else if Option.is_some state.artifact_check_pending then
      Error "A confirmation change is still pending"
    else Ok () in
  let* entries = match visible_resources state with
    | None -> Error "Report inventory has not been read"
    | Some entries -> Ok entries in
  let* selected = Masc_tui_artifact_checks.next_unchecked
    ~reports_complete:state.resources_reports_complete ~entries
    ~cursor:state.resources_cursor state.artifact_checks in
  match Option.bind selected (List.nth_opt entries) with
  | None -> Ok None
  | Some entry ->
    (* The candidate comes from this exact projection; only the caller may
       launch its workspace-owned read or replace the current read owner. *)
    Option.iter (fun cursor -> state.resources_cursor <- cursor) selected;
    Ok (Some (Catalog.key entry))

let place_search_match state ~cols ~query ~count ~index =
  if state.resource_focus = Right_pane && query <> "" && index >= 0 && index < count then
    match Masc_tui_resource_document.current state with
    | Some reading when Masc_tui_resource_reading.searchable reading ->
      state.resource_search_position <- Masc_tui_resource_reading.record_landing
        ~cols ~query ~index reading;
      state.resource_scroll <- Masc_tui_scroll.Position.at index
    | Some _ | None -> ()

let step_text_part state ~delta =
  if state.view = Resources && state.resource_focus = Right_pane then
    let count = Masc_tui_resource_document.text_part_count state in
    if count > 0 then
      state.resource_text_cursor <-
        max 0 (min (count - 1) (state.resource_text_cursor + delta))
