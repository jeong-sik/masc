(** HTTP routes for the verification domain.

    Kept as a dedicated file to avoid bloating
    [server_routes_http_routes_runtime.ml] — the verification domain is
    independent of runtime.

    - [GET /api/v1/verification/requests] — operator view of pending /
      approved / rejected verification requests (see {!Dashboard_verification}).
    - [GET /api/v1/verification/summary] — one-shot status bucket counts +
      most recent rejections (verdict_reason carriers). Lets consumers
      render a compact "X pending / Y approved / Z rejected" card without
      paging the full request list.
    - [GET /api/v1/verification/specs] — TLA+ spec index with clean / buggy
      cfg coverage (see {!Dashboard_tla_specs}).
    - [GET /api/v1/verification/tlc-results] — latest observed TLC log
      projection for each clean / buggy cfg.

    Async Task verification is read-only here. Verdicts are issued only by the
    ordinary Keeper that claimed the Task verifier phase. *)

open Server_auth

module Http = Http_server_eio

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some v when v <> "" -> Some v
  | _ -> None

let add_routes router =
  router
  |> Http.Router.get "/api/v1/verification/requests" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let task_id = trimmed_query_param req "task_id" in
         let limit =
           match trimmed_query_param req "limit" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json =
           Dashboard_verification.requests_json ~base_path ?task_id ?limit ()
         in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/summary" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let recent =
           match trimmed_query_param req "recent" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let base_path = (Mcp_server.workspace_config state).base_path in
         let json = Dashboard_verification.summary_json ~base_path ?recent () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/specs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_tla_specs.specs_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/tlc-results" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_tla_specs.tlc_results_json () in
         Http.Response.json_value ~compress:true ~request:req json reqd
       ) request reqd)
