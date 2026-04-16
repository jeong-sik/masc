(** HTTP routes for the verification domain.

    Kept as a dedicated file to avoid bloating
    [server_routes_http_routes_cascade.ml] — the verification domain is
    independent of cascade.

    - [GET /api/v1/verification/requests] — operator view of pending /
      approved / rejected verification requests (see {!Dashboard_verification}).
    - [GET /api/v1/verification/specs] — TLA+ spec index with clean / buggy
      cfg coverage (see {!Dashboard_tla_specs}). *)

open Server_auth

module Http = Http_server_eio

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some v when v <> "" -> Some v
  | _ -> None

let add_routes router =
  router
  |> Http.Router.get "/api/v1/verification/requests" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let task_id = trimmed_query_param req "task_id" in
         let limit =
           match trimmed_query_param req "limit" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let json =
           Dashboard_verification.requests_json ?task_id ?limit ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/verification/specs" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_tla_specs.specs_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
