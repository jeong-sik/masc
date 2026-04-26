(** HTTP routes for the verification domain.

    Kept as a dedicated file to avoid bloating
    [server_routes_http_routes_cascade.ml] — the verification domain is
    independent of cascade.

    - [GET /api/v1/verification/requests] — operator view of pending /
      approved / rejected verification requests (see {!Dashboard_verification}).
    - [GET /api/v1/verification/summary] — one-shot status bucket counts +
      most recent rejections (verdict_reason carriers). Lets consumers
      render a compact "X pending / Y approved / Z rejected" card without
      paging the full request list.
    - [GET /api/v1/verification/specs] — TLA+ spec index with clean / buggy
      cfg coverage (see {!Dashboard_tla_specs}).
    - [POST /api/v1/verification/resolve] — dashboard-initiated approve/reject
      for a pending verification request. Requires bearer token auth; the
      verifier identity is derived from the authenticated dashboard actor
      when present (otherwise the request hint) and
      namespaced under "operator:" to distinguish from peer-agent verdicts. *)

open Server_auth
module Http = Http_server_eio

let trimmed_query_param req key =
  match Server_utils.query_param req key |> Option.map String.trim with
  | Some v when v <> "" -> Some v
  | _ -> None
;;

let verification_error_json msg : Yojson.Safe.t =
  `Assoc [ "ok", `Bool false; "error", `String msg ]
;;

(* Compose the operator verifier identity. We always prefix with
   "operator:" so attribution/audit can distinguish dashboard verdicts
   from peer-agent verdicts. The actor is canonicalized to the bearer
   owner for authenticated dashboard requests, then sanitized
   (alnum + '_' + '-' only). *)
let verifier_of_request ~base_path request =
  match sanitized_dashboard_actor_for_request ~base_path request with
  | Some hint -> "operator:" ^ hint
  | None -> "operator:dashboard"
;;

let add_routes router =
  router
  |> Http.Router.get "/api/v1/verification/requests" (fun request reqd ->
    with_public_read
      (fun _state req reqd ->
         let task_id = trimmed_query_param req "task_id" in
         let limit =
           match trimmed_query_param req "limit" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let json = Dashboard_verification.requests_json ?task_id ?limit () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd)
      request
      reqd)
  |> Http.Router.get "/api/v1/verification/summary" (fun request reqd ->
    with_public_read
      (fun _state req reqd ->
         let recent =
           match trimmed_query_param req "recent" with
           | Some s -> int_of_string_opt s
           | None -> None
         in
         let json = Dashboard_verification.summary_json ?recent () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd)
      request
      reqd)
  |> Http.Router.get "/api/v1/verification/specs" (fun request reqd ->
    with_public_read
      (fun _state req reqd ->
         let json = Dashboard_tla_specs.specs_json () in
         Http.Response.json ~compress:true ~request:req (Yojson.Safe.to_string json) reqd)
      request
      reqd)
  |> Http.Router.post "/api/v1/verification/resolve" (fun request reqd ->
    with_tool_auth
      ~tool_name:"masc_operator_confirm"
      (fun state req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
           try
             let args = Yojson.Safe.from_string body_str in
             let config = state.Mcp_server.room_config in
             let verifier = verifier_of_request ~base_path:config.base_path req in
             match
               Server_dashboard_http.dashboard_verification_resolve_http_json
                 ~config
                 ~verifier
                 ~args
             with
             | Ok json -> respond_json_with_cors request reqd (Yojson.Safe.to_string json)
             | Error message ->
               respond_json_with_cors
                 ~status:`Bad_request
                 request
                 reqd
                 (Yojson.Safe.to_string (verification_error_json message))
           with
           | Yojson.Json_error msg ->
             respond_json_with_cors
               ~status:`Bad_request
               request
               reqd
               (Yojson.Safe.to_string
                  (verification_error_json (Printf.sprintf "invalid json: %s" msg)))))
      request
      reqd)
;;
