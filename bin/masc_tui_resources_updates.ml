(** Resources response transitions on the UI state owner fiber. *)
open Masc_tui_types
module Catalog = Masc_tui_resource_catalog

type reconciliation = Inventory_updated | Filter_changed

let reconcile reason state =
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
      (match reason, open_key with
       | Inventory_updated, Some (Catalog.Report_revision report)
         when state.resources_reports_complete
           && not (List.exists (fun entry -> Catalog.owns_key entry
             (Catalog.Report_revision report))
             (Option.value state.resources_list ~default:[])) ->
           let prior = match state.resource_content_error with
             | Some (key, prior) when Catalog.equal_key key (Catalog.Report_revision report) ->
               Some prior
             | Some _ | None -> None in
           state.resource_inventory_notice <- Some (report, prior)
       | (Inventory_updated | Filter_changed),
           (Some (Catalog.Mcp_uri _ | Catalog.Report_revision _) | None) -> ());
      state.resource_pending_key <- None;
      state.resource_read_owner <- None;
      state.resource_revision_history <- [];
      state.resource_shared <- None;
      state.resource_share_version <- None;
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
    reconcile Inventory_updated state
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
    let open Result.Syntax in
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
  state.resource_inventory_notice <- None;
  state.resource_scope <- scope;
  state.resources_cursor <- 0;
  state.search <- None;
  state.search_last <- "";
  reconcile Filter_changed state

let toggle_today state ~now =
  state.resource_day <- (match state.resource_day with
    | None -> Some (Catalog.local_day now)
    | Some _ -> None);
  select_scope state state.resource_scope

let reset_document_position state =
  state.resource_scroll <- Masc_tui_scroll.Position.first;
  state.resource_search_position <- Masc_tui_resource_reading.first

let retain_unread_revision state key =
  match state.resource_content, state.resource_content_error with
  | None, None ->
    (* A retired read can be the only owner of this fixed revision. *)
    state.resource_content_error <- Some
      (key, "Report is not currently read; press R to reread this revision")
  | (Some _ | None), (Some _ | None) -> ()

let begin_share_recovery_lookup state ~origin ~report =
  let key = Catalog.Report_revision report in
  (* An earlier read may already be queued with an older empty journal. *)
  (match state.resource_pending_key with
   | Some pending when Catalog.equal_key pending key ->
     (match state.resource_content with
      | Some (held, _) when Catalog.equal_key held key -> ()
      | Some _ | None -> state.resource_content_error <- Some (key, "Press R to reread this report"));
     state.resource_pending_key <- None
   | Some _ | None -> ());
  state.resource_read_owner <- None;
  state.resource_copy_pending <- None;
  let uncertain_key = origin, report.id in
  if not (List.mem uncertain_key state.resource_share_uncertain_ids) then
    state.resource_share_uncertain_ids <- uncertain_key :: state.resource_share_uncertain_ids

let begin_share_change ?(recovery = false) state ~report ~(entry : Masc_tui_artifact_share_pending.entry) =
  if not (server_authority_ready state) then Error "Workspace identity is unconfirmed"
  else if resource_share_uncertain state report && not recovery then
    Error "External sharing outcome is unconfirmed; an operation receipt is required"
  else match workspace_input_identity_of_server state.server_identity with
  | None -> Error "Workspace identity is unconfirmed"
  | Some share_workspace_identity when
      entry.base_path <> share_workspace_identity.wi_base_path
      || entry.masc_root <> share_workspace_identity.wi_masc_root
      || entry.artifact_id <> report.Catalog.id ->
    Error "The share request belongs to another workspace or artifact"
  | Some _ when resource_share_identity_conflict state entry ->
    Error "The recovered operation ID does not match the originally observed request"
  | Some share_workspace_identity when List.exists (fun request ->
      request.share_workspace_identity = share_workspace_identity
      && String.equal request.share_report.id report.id) state.resource_share_pending ->
    Error "An external sharing change for this artifact is still pending"
  | Some share_workspace_identity ->
    let request = { share_owner = ref (); share_workspace = state.workspace_authority;
      share_workspace_identity; share_report = report; share_target = entry.request.requested;
      share_recovery = recovery; share_entry = entry } in
    state.resource_share_pending <- request :: state.resource_share_pending;
    state.resource_shared <- None;
    state.resource_share_version <- None;
    (match state.resource_pending_key with
     | Some key when Catalog.equal_key key (Catalog.Report_revision report) ->
       retain_unread_revision state key
     | Some _ | None -> ());
    state.resource_pending_key <- None;
    state.resource_read_owner <- None;
    Ok request

(* Sharing belongs to the artifact, including every fixed revision. Keep the
   guard across authority changes too: a read in a successor generation may
   have started before the older write settled against the same workspace. *)
let share_matches_workspace state request =
  workspace_input_identity_of_server state.server_identity = Some request.share_workspace_identity

let share_matches_key state request = function
  | Catalog.Report_revision report ->
    share_matches_workspace state request && String.equal request.share_report.id report.id
  | Catalog.Mcp_uri _ -> false

let share_changed state request ~result =
  match List.find_opt (fun current -> current.share_owner == request.share_owner) state.resource_share_pending with
  | Some current ->
    let request = current in
    let current_key = match Masc_tui_resource_document.current state with
      | Some { entry = Catalog.Report report; _ }
        when share_matches_key state request (Catalog.Report_revision report) ->
        Some (Catalog.Report_revision report)
      | Some { entry = Catalog.Mcp _; _ }
      | Some { entry = Catalog.Report _; _ }
      | None -> None in
    let uncertain_key = request.share_workspace_identity, request.share_report.id in
    (match result with
     | Ok (Resource_share_applied _ | Resource_share_conflict _) ->
       settle_resource_share state request.share_entry;
       state.resource_share_uncertain_ids <- List.filter ((<>) uncertain_key) state.resource_share_uncertain_ids
     | Ok (Resource_share_not_sent _) | Error (Resource_share_unknown _) ->
       observe_resource_share state request.share_entry;
       if not (List.mem uncertain_key state.resource_share_uncertain_ids) then
         state.resource_share_uncertain_ids <- uncertain_key :: state.resource_share_uncertain_ids
     | Ok (Resource_share_not_prepared _) | Error (Resource_share_not_started _) -> ());
    state.resource_share_pending <- List.filter
      (fun current -> current.share_owner != request.share_owner) state.resource_share_pending;
    (* Even a read launched after the POST can have observed its old state.
       Retire it on settlement before a caller asks for a fresh observation. *)
    (match state.resource_pending_key with
     | Some key when share_matches_key state request key ->
       retain_unread_revision state key;
       state.resource_pending_key <- None;
       state.resource_read_owner <- None
     | Some _ | None -> ());
    Option.iter (fun _ -> state.resource_shared <- None; state.resource_share_version <- None) current_key;
    if share_matches_workspace state request && server_authority_ready state
    then current_key else None
  | None -> None

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
       state.resource_shared <- (match key with
         | _ when List.exists (fun pending -> share_matches_key state pending key) state.resource_share_pending -> None
         | Catalog.Report_revision report
           when resource_share_uncertain state report -> None
         | Catalog.Report_revision _ | Catalog.Mcp_uri _ -> reading.shared);
       state.resource_share_version <- (match state.resource_shared with
         | Some _ -> reading.share_version | None -> None);
       state.resource_image_cursor <- 0;
       state.resource_text_cursor <- 0;
       state.resource_search_position <- Masc_tui_resource_reading.first;
       state.resource_content_error <- None
     | Error detail ->
       (* Keep the last versioned observation for a possible revoke. An
          enable still requires a readable body, and the server compares this
          retained share version and publication before applying either write. *)
       state.resource_content_error <- Some (key, detail))
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
  let open Result.Syntax in
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
