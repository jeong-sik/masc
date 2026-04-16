open Server_auth

module Http = Http_server_eio

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
