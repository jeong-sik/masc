open Server_auth
open Server_utils

module Http = Http_server_eio

(* Bounds mirror the .mli contract: dashboard asks for ≤ 1024 events
   per poll; anything smaller than 1 would produce an empty response. *)
let clamp_history_limit n = max 1 (min 1024 n)

(* Only forward well-known kind strings.  Unknown values are dropped
   (passed through as [None]) so the projection returns every kind
   rather than the "unknown kind → []" behaviour reserved for explicit
   unknown filters.  Rationale: a typo in a dashboard query param
   should not silently zero out the response. *)
let parse_history_kind = function
  | Some ("cli" | "ollama" | "other") as ok -> ok
  | _ -> None

let parse_history_since request =
  match query_param request "since_ts" with
  | None -> None
  | Some s -> float_of_string_opt (String.trim s)

let add_routes router =
  router
  |> Http.Router.get "/api/v1/cascade/config" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cascade.config_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/cascade/health" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cascade.health_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/cascade/client_capacity" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cascade.client_capacity_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/cascade/client_capacity/history"
       (fun request reqd ->
         with_public_read (fun _state req reqd ->
           let limit =
             clamp_history_limit (int_query_param req "limit" ~default:100)
           in
           let kind = parse_history_kind (query_param req "kind") in
           let since_ts = parse_history_since req in
           let json =
             Dashboard_cascade.client_capacity_history_json
               ~limit ?kind ?since_ts ()
           in
           Http.Response.json ~compress:true ~request:req
             (Yojson.Safe.to_string json) reqd
         ) request reqd)
