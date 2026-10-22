(** Both transports retain the caller-owned workspace JSON read boundary. *)
open Masc_tui_types
open Masc_tui_async_protocol
module Catalog = Masc_tui_resource_catalog

let ( let* ) = Result.bind

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

let launch_read state ~host ~launch ~check ~key =
  retain_resource_read state ~key;
  if server_authority_ready state then begin
    let owner = ref () in
    state.resource_read_owner <- Some owner;
    let request = { Catalog.key; owner } in
    let port = state.port in
    let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
    let captured_session = state.mcp_session in
    launch
      ~deliver:(fun result -> Resource_read
        (request, Masc_tui_async_read.attribute Masc_tui_async_read.Resource_read result))
      (fun () -> match key with
        | Catalog.Mcp_uri uri ->
          let* session_id = session ~host ~port captured_session in
          let* () = check () in
          Masc_tui_http.call_mcp_resources_read ~host ~port ~session_id ~request_id ~uri
          |> Result.map Catalog.mcp_reading
        | Catalog.Report_revision report ->
          let* () = check () in
          let* json = report_json ~host ~port ~path:(Catalog.report_path report) in
          Catalog.report_contents report json)
  end
