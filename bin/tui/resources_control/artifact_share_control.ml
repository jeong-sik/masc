module T = Masc_tui_types
module P = Masc_tui_async_protocol
module Admission = Masc_tui_transport.Workspace_admission
module Request_notice = Masc_tui_transport.Request_notice
module Kept_request = Masc_tui_words.Kept_request
module Catalog = Masc_tui_resource_catalog
module Reading = Masc_tui_resource_reading
module Artifact_share_pending = Masc_tui_artifact_share_pending

let artifact_share_journal_path (origin : T.workspace_input_identity) =
  Artifact_share_pending.journal_path ~masc_root:origin.T.wi_masc_root

let open_resource_report (state : T.state) =
  match Masc_tui_resource_document.current state with
  | Some {Reading.entry = Catalog.Report report; _} -> Ok report
  | Some {Reading.entry = Catalog.Mcp _; _} | None -> Error "Open a published report in the detail pane"

(* The share POST the workspace guard stopped: the notice, the report, and
   the way to settle the intent already recorded for it, which a later
   attempt may still apply. *)
let report_resource_share_kept_back (state : T.state) (request : T.resource_share_request) refusal =
  let ko = state.T.ui_language = T.Lang_ko in
  Masc_tui_loader.report_action state "error"
    (String.concat " · "
       [ T.workspace_refusal_text ~ko ~request:Kept_request.Resource_share refusal
       ; request.T.share_report.Catalog.id
       ; (if ko then "U 로 기록된 작업을 맞추세요" else "use U to reconcile the recorded operation") ])

let launch_resource_share (state : T.state) ~mailbox ~(report : Catalog.report)
    ~(entry : Artifact_share_pending.entry) ~recovery ~dispatch_allowed =
  let captured_authority = state.T.workspace_authority in
  match state.T.server_identity, T.workspace_change_origin state with
  | Some expected_workspace, Ok origin
    when entry.Artifact_share_pending.base_path = origin.T.wi_base_path
         && entry.Artifact_share_pending.masc_root = origin.T.wi_masc_root
         && entry.Artifact_share_pending.artifact_id = report.Catalog.id ->
    let operation = entry.Artifact_share_pending.request in
    let path = artifact_share_journal_path origin in
    let on_observed entries =
      List.iter (fun (observed : Artifact_share_pending.entry) ->
        if observed.Artifact_share_pending.masc_root = origin.T.wi_masc_root then
          T.record_resource_share_observation state observed) entries in
    (match Masc_tui_resources_updates.begin_share_change ~recovery state ~report ~entry with
     | Error (T.Request_failed detail) -> Masc_tui_loader.report_action state "error" detail
     | Error (T.Request_withdrawn refusal) ->
       Request_notice.report_withdrawn state ~request:Kept_request.Resource_share refusal
     | Ok request ->
       Masc_tui_loader.report_action state "system" (if recovery then
         "Reconciling the original share operation; it may be applied now"
         else if operation.Masc.Published_artifact_share.requested then "Enabling external sharing"
         else "Revoking external sharing");
       let credential = Masc_tui_http.bind_credential () in
       let host = Admission.server_peer_host and port = state.T.port in
       let identity = Some expected_workspace in
       let context detail = Printf.sprintf
         "operation %s, observed share version %d, publication v%d (%s): %s"
         operation.Masc.Published_artifact_share.operation_id
         operation.Masc.Published_artifact_share.expected_version
         operation.Masc.Published_artifact_share.expected_artifact_revision
         operation.Masc.Published_artifact_share.expected_artifact_sha256 detail in
       let journal_started = ref false in
       let attempt = Masc_tui_artifact_share_attempt.create () in
       let failure detail =
         if !journal_started || Masc_tui_artifact_share_attempt.dispatched attempt
         then T.Resource_share_unknown (context detail) else T.Resource_share_not_started detail in
       Admission.launch_result ~operation:true state ~mailbox
         ~boundary_error:failure
         ~cancelled_by:(fun () -> P.Resource_msg (P.Resource_share_changed (request, Error (failure "interrupted"))))
         ~deliver:(fun result -> P.Resource_msg (P.Resource_share_changed (request, result)))
         (fun () ->
           (* The filesystem transaction and its lock belong to this worker, not
              to the input loop. A cancelled system-thread write may finish. *)
           journal_started := true;
           let prepared = if recovery then
               Artifact_share_pending.restore ~on_observed ~path entry |> Result.map (fun () -> Artifact_share_pending.Prepared)
             else Artifact_share_pending.prepare_checked ~on_observed ~path entry in
           match prepared with
           | Error detail -> Error (T.Resource_share_unknown (context ("Share intent storage could not be confirmed: " ^ detail)))
           | Ok (Artifact_share_pending.Not_prepared detail) ->
             Ok (T.Resource_share_not_prepared ("Share intent was not recorded: " ^ detail))
           | Ok (Artifact_share_pending.Already_pending _) ->
             Ok (T.Resource_share_not_prepared "Another recorded share operation must be resolved first")
           | Ok (Artifact_share_pending.Already_pending_with_storage_failure (_, detail)) ->
             Ok (T.Resource_share_not_prepared ("Another operation was observed; journal storage failed: " ^ detail))
           | Ok Artifact_share_pending.Prepared ->
             match Masc_tui_artifact_share_attempt.perform attempt
               ~preflight:(fun () ->
                 match Admission.admit_request state ~mailbox ~authority:captured_authority ~identity ~host ~port () with
                 | Error refusal -> Error (T.Request_withdrawn refusal)
                 | Ok () ->
                   (match T.resource_share_dispatch_refusal state ~origin ~entry ~recovery with
                    | Some detail -> Error (T.Request_failed detail)
                    | None when dispatch_allowed () -> Ok ()
                    | None -> Error (T.Request_failed "An interrupt or termination is awaiting handling")))
               ~send:(fun () -> Masc_tui_http.post_artifact_share ~credential ~expected_workspace
                 ~host ~port ~id:entry.Artifact_share_pending.artifact_id
                 ~shared:operation.Masc.Published_artifact_share.requested
                 ~operation_id:operation.Masc.Published_artifact_share.operation_id
                 ~expected_version:operation.Masc.Published_artifact_share.expected_version
                 ~expected_artifact_revision:operation.Masc.Published_artifact_share.expected_artifact_revision
                 ~expected_artifact_sha256:operation.Masc.Published_artifact_share.expected_artifact_sha256) with
             | Masc_tui_artifact_share_attempt.Not_sent (T.Request_failed detail) -> Ok (T.Resource_share_not_sent detail)
             | Masc_tui_artifact_share_attempt.Not_sent (T.Request_withdrawn refusal) -> Ok (T.Resource_share_kept_back refusal)
             | Masc_tui_artifact_share_attempt.Sent (Error detail) -> Error (T.Resource_share_unknown (context detail))
             | Masc_tui_artifact_share_attempt.Sent (Ok result) ->
               (match Artifact_share_pending.settle ~on_observed ~path entry with
                | Error detail -> Error (T.Resource_share_unknown
                    (context ("Receipt arrived but recovery storage did not settle: " ^ detail)))
                | Ok _ -> Ok (match result with
                  | Masc_tui_http.Artifact_share_applied shared -> T.Resource_share_applied shared
                  | Masc_tui_http.Artifact_share_conflict shared -> T.Resource_share_conflict shared))))
  | (Some _ | None), (Ok _ | Error _) ->
    Masc_tui_loader.report_action state "error" "The original share operation belongs to a different or unverified workspace"

let toggle_resource_external_share (state : T.state) ~mailbox ~dispatch_allowed =
  state.T.resource_share_recovery_prompt <- None;
  match Masc_tui_resource_document.external_share_change state, T.workspace_change_origin state with
  | Error detail, _ | _, Error detail -> Masc_tui_loader.report_action state "error" detail
  | Ok ((report : Catalog.report), shared), Ok origin ->
    (match state.T.resource_share_version, state.T.resource_revision_history with
     | Some expected_version, (latest : Catalog.report) :: _ when String.equal latest.Catalog.id report.Catalog.id ->
       let request : Masc.Published_artifact_share.request = {
         operation_id=Random_id.uuid_v7 (); expected_version; requested=shared;
         expected_artifact_revision=latest.Catalog.revision.Masc.Published_artifact.revision;
         expected_artifact_sha256=latest.Catalog.revision.Masc.Published_artifact.body.Tool_output.sha256 } in
       let entry : Artifact_share_pending.entry = {
         Artifact_share_pending.base_path=origin.T.wi_base_path;
         masc_root=origin.T.wi_masc_root; artifact_id=report.Catalog.id; request} in
       launch_resource_share state ~mailbox ~report ~entry ~recovery:false ~dispatch_allowed
     | Some _, _ :: _ | Some _, [] | None, ([] | _ :: _) ->
       Masc_tui_loader.report_action state "error" "Share version or latest publication is unavailable; reread this report")

let begin_resource_share_recovery_lookup (state : T.state) ~mailbox =
  match open_resource_report state, T.workspace_change_origin state, state.T.resource_share_recovery_lookup with
  | Error detail, _, _ | _, Error detail, _ -> Masc_tui_loader.report_action state "error" detail
  | Ok _, Ok _, Some _ -> Masc_tui_loader.report_action state "system" "Checking the recorded share operation"
  | Ok report, Ok origin, None when List.exists (fun (pending : T.resource_share_request) ->
      pending.T.share_workspace_identity = origin && String.equal pending.T.share_report.Catalog.id report.Catalog.id)
      state.T.resource_share_pending ->
    Masc_tui_loader.report_action state "system" "A sharing attempt for this artifact is still running; wait for its result."
  | Ok report, Ok origin, None ->
    let request = { T.recovery_lookup_owner=ref (); recovery_lookup_workspace=state.T.workspace_authority;
      recovery_lookup_origin=origin; recovery_lookup_key=Catalog.Report_revision report } in
    Masc_tui_resources_updates.begin_share_recovery_lookup state ~origin ~report;
    state.T.resource_share_recovery_lookup <- Some request;
    Masc_tui_loader.report_action state "system" "Checking the recorded share operation";
    let path = artifact_share_journal_path origin in
    Admission.launch_result ~observation:true state ~mailbox
      ~boundary_error:Fun.id
      ~cancelled:(P.Resource_msg (P.Resource_share_recovery_loaded (request, Error "Recovery lookup interrupted")))
      ~deliver:(fun result -> P.Resource_msg (P.Resource_share_recovery_loaded (request, result)))
      (fun () ->
        let on_observed entries = List.iter (fun (entry : Artifact_share_pending.entry) ->
          if entry.Artifact_share_pending.masc_root = origin.T.wi_masc_root then
            T.record_resource_share_observation state entry) entries in
        Artifact_share_pending.observe ~on_observed ~path () |> Result.map (fun (_, entries) ->
          List.find_opt (fun (entry : Artifact_share_pending.entry) ->
            entry.Artifact_share_pending.base_path = origin.T.wi_base_path
            && entry.Artifact_share_pending.masc_root = origin.T.wi_masc_root
            && entry.Artifact_share_pending.artifact_id = report.Catalog.id) entries))

let recover_resource_external_share (state : T.state) ~mailbox ~confirm ~dispatch_allowed =
  if not confirm then begin_resource_share_recovery_lookup state ~mailbox
  else match open_resource_report state, T.workspace_change_origin state, state.T.resource_share_recovery_prompt with
  | Ok report, Ok origin, Some held
    when held.T.recovery_workspace = state.T.workspace_authority
         && held.T.recovery_entry.Artifact_share_pending.base_path = origin.T.wi_base_path
         && held.T.recovery_entry.Artifact_share_pending.masc_root = origin.T.wi_masc_root
         && Catalog.equal_key held.T.recovery_key (Catalog.Report_revision report) ->
    if Masc_tui_artifact_share_confirmation.ready held.T.recovery_confirmation then begin
      state.T.resource_share_recovery_prompt <- None;
      launch_resource_share state ~mailbox ~report ~entry:held.T.recovery_entry ~recovery:true ~dispatch_allowed
    end else Masc_tui_loader.report_action state "system" "Wait for the recovery preview before confirming."
  | (Ok _ | Error _), (Ok _ | Error _), (Some _ | None) ->
    state.T.resource_share_recovery_prompt <- None;
    Masc_tui_loader.report_action state "system" "Press U to inspect the current recovery operation first."

let resource_share_is_owned (state : T.state) (request : T.resource_share_request) =
  List.exists (fun (current : T.resource_share_request) -> current.T.share_owner == request.T.share_owner) state.T.resource_share_pending

let resource_public_copy_is_current (state : T.state) (copy : T.resource_public_copy) =
  state.T.view = T.Resources && state.T.resource_focus = T.Right_pane
  && state.T.workspace_authority = copy.T.public_copy_workspace
  && state.T.workspace_read_authority == copy.T.public_copy_read_authority
  && T.workspace_change_origin state = Ok copy.T.public_copy_origin
  && match Masc_tui_resource_document.current state with
     | Some reading ->
       Catalog.equal_key (Catalog.key reading.Reading.entry) copy.T.public_copy_key
       && reading.Reading.public_url = Some (Ok copy.T.public_copy_url)
     | None -> false

let finish_resource_share ~withdraw_diagram (state : T.state) (request : T.resource_share_request) result =
  withdraw_diagram state;
  let read_key = Masc_tui_resources_updates.share_changed state request ~result in
  let key = request.T.share_workspace_identity, request.T.share_report.Catalog.id in
  match result with
  | Ok (T.Resource_share_applied _ | T.Resource_share_conflict _) -> read_key
  | Ok (T.Resource_share_not_prepared _) -> read_key
  | Error (T.Resource_share_not_started _) when not request.T.share_recovery -> read_key
  | Ok (T.Resource_share_not_sent _ | T.Resource_share_kept_back _)
  | Error (T.Resource_share_unknown _ | T.Resource_share_not_started _) ->
    if not (List.mem key state.T.resource_share_uncertain_ids) then
      state.T.resource_share_uncertain_ids <- key :: state.T.resource_share_uncertain_ids;
    None
