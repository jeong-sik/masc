(** Both transports retain the caller-owned workspace JSON read boundary. *)
open Masc_tui_types
open Masc_tui_async_protocol
module Catalog = Masc_tui_resource_catalog

open Result.Syntax

let report_json = Masc_tui_http.get_json

let session ~host ~port = function
  | Some session_id -> Ok session_id
  | None -> Masc_tui_http.open_mcp_session ~host ~port
      ~client_version:Runtime_build_version.current

let launch_list state ~host ~launch ~check =
  if server_authority_ready state then begin
    let owner = Masc_tui_resources_updates.begin_listing state in
    let port = state.port in
    let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
    let captured_session = state.mcp_session in
    launch ~deliver:(fun result -> Resources_listed (owner, result)) (fun () ->
      let mcp =
        let* session_id = session ~host ~port captured_session in
        let* () = check () in
        Masc_tui_http.call_mcp_resources_list ~host ~port ~session_id ~request_id in
      (* A failed MCP session must not hide authorized reports. Recheck before
         the separate admin API, even when MCP succeeded. *)
      let* () = check () in
      let reports =
        let* json = report_json ~host ~port ~path:"/api/v1/published-artifacts" in
        Catalog.reports_of_json json in
      Catalog.combine mcp reports)
  end

let launch_read state ~host ~share_origin ~launch ~check ~key =
  retain_resource_read state ~key;
  if server_authority_ready state then begin
    let owner = ref () in
    state.resource_read_owner <- Some owner;
    let request = { Catalog.key; owner } in
    let port = state.port in
    let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
    let captured_session = state.mcp_session in
    launch
      ~deliver:(fun result ->
        let content, journal = match result with
          | Ok pair -> pair
          | Error detail -> Error detail, Share_journal_unavailable (detail, []) in
        Resource_read (request,
          Masc_tui_async_read.attribute Masc_tui_async_read.Resource_read content, journal))
      (fun () -> match key with
        | Catalog.Mcp_uri uri ->
          let content =
            let* session_id = session ~host ~port captured_session in
            let* () = check () in
            Masc_tui_http.call_mcp_resources_read ~host ~port ~session_id ~request_id ~uri
            |> Result.map Catalog.mcp_reading in
          Ok (content, Share_journal_not_needed)
        | Catalog.Report_revision report ->
          let observe () = match share_origin with
            | None -> Error "Share recovery requires the verified local workspace"
            | Some origin ->
              let on_observed entries = List.iter (fun (entry : Masc_tui_artifact_share_pending.entry) ->
                if entry.masc_root = origin.wi_masc_root then record_resource_share_observation state entry) entries in
              Masc_tui_artifact_share_pending.observe ~on_observed
                ~path:(Masc_tui_artifact_share_pending.journal_path ~masc_root:origin.wi_masc_root) () in
          let before = observe () in
          let content =
            let* () = check () in
            let* json = report_json ~host ~port ~path:(Catalog.report_path report) in
            Catalog.report_contents report json in
          let after = observe () in
          let observed_entries result = match share_origin, result with
            | Some origin, Ok (_, entries) -> List.filter (fun (entry : Masc_tui_artifact_share_pending.entry) ->
                entry.base_path = origin.wi_base_path && entry.masc_root = origin.wi_masc_root
                && entry.artifact_id = report.id) entries
            | (Some _ | None), (Ok _ | Error _) -> [] in
          let observed = List.fold_left (fun acc entry -> Masc_tui_artifact_share_pending.witness entry acc)
            [] (observed_entries before @ observed_entries after) in
          let journal = match share_origin, before, after with
            | Some origin, Ok (before, _), Ok (after, entries) ->
              let pending = List.find_opt (fun (entry : Masc_tui_artifact_share_pending.entry) ->
                entry.base_path = origin.wi_base_path && entry.masc_root = origin.wi_masc_root
                && entry.artifact_id = report.id) entries in
              Share_journal_checked {journal_workspace=origin;journal_pending=pending;journal_observed=observed;
                journal_stable=(before = after && Option.is_none pending && observed = [])}
            | (Some _ | None), Error detail, (Ok _ | Error _) -> Share_journal_unavailable (detail, observed)
            | (Some _ | None), Ok _, Error detail -> Share_journal_unavailable (detail, observed)
            | None, Ok _, Ok _ -> Share_journal_unavailable ("Share recovery workspace is unavailable", observed) in
          let content = match journal with
            | Share_journal_checked {journal_stable=true;_} -> content
            | Share_journal_checked _ | Share_journal_unavailable _ | Share_journal_not_needed ->
              Result.map (fun (reading : Catalog.reading) -> {reading with shared=None;share_version=None}) content in
          Ok (content, journal))
  end
