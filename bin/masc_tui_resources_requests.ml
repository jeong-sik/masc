(** MCP resource list and content request execution. *)

open Masc_tui_types
open Masc_tui_async_protocol

let launch_list state ~host ~deliver =
  let port = state.port in
  let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
  let session = state.mcp_session in
  Masc_tui_async_read.launch
    ~deliver:(fun result -> deliver (Resources_listed result))
    (fun () ->
       let session_result =
         match session with
         | Some session_id -> Ok session_id
         | None ->
           Masc_tui_http.open_mcp_session
             ~host
             ~port
             ~client_version:Runtime_build_version.current
       in
       match session_result with
       | Error detail -> Error detail
       | Ok session_id ->
         Masc_tui_http.call_mcp_resources_list ~host ~port ~session_id ~request_id)
;;

let launch_read state ~host ~deliver ~uri =
  let same_resource =
    match state.resource_content with
    | Some (current, _) -> String.equal current uri
    | None -> false
  in
  state.resource_pending_uri <- Some uri;
  if not same_resource
  then (
    state.resource_content <- None;
    state.resource_content_error <- None;
    state.resource_scroll <- 0);
  let port = state.port in
  let request_id = Printf.sprintf "tui-res-%.6f" (Unix.gettimeofday ()) in
  let session = state.mcp_session in
  Masc_tui_async_read.launch
    ~source:Masc_tui_async_read.Resource_read
    ~deliver:(fun result -> deliver (Resource_read (uri, result)))
    (fun () ->
       let session_result =
         match session with
         | Some session_id -> Ok session_id
         | None ->
           Masc_tui_http.open_mcp_session
             ~host
             ~port
             ~client_version:Runtime_build_version.current
       in
       match session_result with
       | Error detail -> Error detail
       | Ok session_id ->
         Masc_tui_http.call_mcp_resources_read ~host ~port ~session_id ~request_id ~uri)
;;
