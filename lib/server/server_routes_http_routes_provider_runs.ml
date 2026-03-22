
open Server_utils
open Server_auth

module Http = Http_server_eio

let add_routes ~sw router =
  router
  |> Http.Router.get "/api/v1/providers" (fun request reqd ->
       with_public_read (fun _state req reqd ->
         let json = Dashboard_provider_runs.provider_inventory_json () in
         Http.Response.json ~compress:true ~request:req
           (Yojson.Safe.to_string json) reqd
       ) request reqd)
  |> Http.Router.post "/api/v1/agent-runs" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun _state _agent_name _req reqd ->
         Http.Request.read_body_async reqd (fun body_str ->
             try
               let json = Yojson.Safe.from_string body_str in
               let open Yojson.Safe.Util in
               let provider = json |> member "provider" |> to_string in
               let model_opt = json |> member "model" |> to_string_option in
               let prompt = json |> member "prompt" |> to_string in
               match
                 Dashboard_provider_runs.start_run ~sw ~provider ~model_opt
                   ~prompt
               with
               | Ok payload ->
                   respond_json_with_cors ~status:`Created request reqd
                     (Yojson.Safe.to_string payload)
               | Error message ->
                   respond_json_with_cors ~status:`Bad_request request reqd
                     (Yojson.Safe.to_string
                        (`Assoc [ ("error", `String message) ]))
             with
             | Yojson.Json_error error ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ( "error",
                            `String ("invalid json: " ^ error) );
                        ]))
             | Yojson.Safe.Util.Type_error (error, _) ->
                 respond_json_with_cors ~status:`Bad_request request reqd
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ( "error",
                            `String ("invalid request shape: " ^ error) );
                        ])))
       ) request reqd)
  |> Http.Router.prefix_get "/api/v1/agent-runs/" (fun request reqd ->
       with_read_auth (fun _state req reqd ->
         let req_path = Http.Request.path req in
         match extract_path_param ~prefix:"/api/v1/agent-runs/" req_path with
         | None ->
             respond_json_with_cors ~status:`Bad_request request reqd
               (Yojson.Safe.to_string
                  (`Assoc [ ("error", `String "run_id is required") ]))
         | Some run_id ->
             (match Dashboard_provider_runs.run_status_json run_id with
             | Ok payload ->
                 respond_json_with_cors request reqd
                   (Yojson.Safe.to_string payload)
             | Error message ->
                 respond_json_with_cors ~status:`Not_found request reqd
                   (Yojson.Safe.to_string
                      (`Assoc [ ("error", `String message) ])))
       ) request reqd)
