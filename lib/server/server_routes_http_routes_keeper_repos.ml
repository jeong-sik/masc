open Server_auth
open Server_utils

module Http = Http_server_eio

let mapping_json (m : Repo_manager_types.keeper_repo_mapping) : Yojson.Safe.t =
  `Assoc
    [
      ("keeper_id", `String m.keeper_id);
      ("repositories", `List (List.map (fun s -> `String s) m.repository_ids));
    ]

let mapping_of_json keeper_id (json : Yojson.Safe.t) :
    (Repo_manager_types.keeper_repo_mapping, string) result =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt "repositories" fields with
      | Some (`List items) ->
          let repository_ids =
            List.filter_map
              (function `String s -> Some s | _ -> None)
              items
          in
          Ok { Repo_manager_types.keeper_id; repository_ids }
      | Some _ -> Error "field repositories must be an array of strings"
      | None -> Error "missing field repositories")
  | _ -> Error "expected JSON object body"

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/keepers/" (fun request reqd ->
       with_public_read (fun state req reqd ->
         let base_path = state.Mcp_server.room_config.base_path in
         let path = Http.Request.path request in
         match extract_path_param ~prefix:"/api/v1/keepers/" path with
         | None | Some "" ->
             Http.Response.json ~status:`Bad_request ~request:req
               (Yojson.Safe.to_string
                  (`Assoc
                    [
                      ("ok", `Bool false);
                      ("error", `String "missing keeper id");
                    ]))
               reqd
         | Some rest -> (
             match String.split_on_char '/' rest with
             | keeper_id :: "repos" :: [] -> (
                 match
                   Keeper_repo_mapping.allowed_repositories ~keeper_id ~base_path
                 with
                 | Error msg ->
                     Http.Response.json ~status:`Not_found ~request:req
                       (Yojson.Safe.to_string
                          (`Assoc
                            [
                              ("ok", `Bool false); ("error", `String msg);
                            ]))
                       reqd
                 | Ok repo_ids ->
                     let json =
                       `Assoc
                         [
                           ("keeper_id", `String keeper_id);
                           ( "repositories",
                             `List (List.map (fun s -> `String s) repo_ids) );
                         ]
                     in
                     Http.Response.json ~compress:true ~request:req
                       (Yojson.Safe.to_string json)
                       reqd)
             | _ ->
                 Http.Response.json ~status:`Bad_request ~request:req
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ("ok", `Bool false);
                          ( "error",
                            `String "expected path /api/v1/keepers/:id/repos" );
                        ]))
                   reqd)
       ) request reqd)
  |> Http.Router.prefix_post "/api/v1/keepers/" (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state _agent_name req reqd ->
           let base_path = state.Mcp_server.room_config.base_path in
           let path = Http.Request.path request in
           match extract_path_param ~prefix:"/api/v1/keepers/" path with
           | None | Some "" ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc
                      [
                        ("ok", `Bool false);
                        ("error", `String "missing keeper id");
                      ]))
                 reqd
           | Some rest -> (
               match String.split_on_char '/' rest with
               | keeper_id :: "repos" :: [] ->
                   Http.Request.read_body_async reqd (fun body_str ->
                     let response status message =
                       Http.Response.json ~status ~request:req
                         (Yojson.Safe.to_string
                            (`Assoc
                              [
                                ("ok", `Bool false);
                                ("error", `String message);
                              ]))
                         reqd
                     in
                     match Yojson.Safe.from_string body_str with
                     | exception Yojson.Json_error msg ->
                         response `Bad_request ("invalid JSON body: " ^ msg)
                     | json -> (
                         match mapping_of_json keeper_id json with
                         | Error msg -> response `Bad_request msg
                         | Ok mapping -> (
                             match
                               Keeper_repo_mapping.save_mapping ~base_path mapping
                             with
                             | Error msg -> response `Bad_request msg
                             | Ok () ->
                                 Http.Response.json ~request:req
                                   (Yojson.Safe.to_string (mapping_json mapping))
                                   reqd)))
               | _ ->
                   Http.Response.json ~status:`Bad_request ~request:req
                     (Yojson.Safe.to_string
                        (`Assoc
                          [
                            ("ok", `Bool false);
                            ( "error",
                              `String
                                "expected path /api/v1/keepers/:id/repos" );
                          ]))
                     reqd)
         ) request reqd)
