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

let raw_json_of_body body_str =
  match Yojson.Safe.from_string body_str with
  | `Assoc fields -> (
      match List.assoc_opt "raw_json" fields with
      | Some (`String raw_json) -> Ok raw_json
      | _ -> Error "expected JSON body with string field raw_json")
  | _ -> Error "expected JSON object body"

let is_toml_source_error msg =
  String.starts_with ~prefix:"active cascade source is TOML" msg

let add_routes router =
  router
  |> Http.Router.get "/api/v1/cascade/config" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cascade.config_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/cascade/config/raw" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cascade.raw_config_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/cascade/config/raw" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun _state _agent_name req reqd ->
           Http.Request.read_body_async reqd (fun body_str ->
             let response status message =
               Http.Response.json ~status ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc [ ("ok", `Bool false); ("error", `String message) ]))
                 reqd
             in
             match raw_json_of_body body_str with
             | exception Yojson.Json_error msg ->
                 response `Bad_request ("invalid JSON body: " ^ msg)
             | Error msg ->
                 response `Bad_request msg
             | Ok raw_json -> (
                 match Dashboard_cascade.save_raw_config_json raw_json with
                 | Ok json ->
                     Http.Response.json ~request:req
                       (Yojson.Safe.to_string json) reqd
                 | Error msg ->
                     response
                       (if is_toml_source_error msg then `Conflict
                        else `Bad_request)
                       msg))
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
  |> Http.Router.get "/api/v1/cascade/strategy_trace" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let limit =
           clamp_history_limit (int_query_param req "limit" ~default:100)
         in
         let cascade = query_param req "cascade" in
         let json =
           Dashboard_cascade.strategy_trace_json ~limit ?cascade ()
         in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.get "/api/v1/cascade/slo" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_cascade.slo_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
