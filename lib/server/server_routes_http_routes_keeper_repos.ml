open Server_auth
open Server_utils

module Http = Http_server_eio

let mappings_path = "/api/v1/keeper-repos"
let mapping_prefix = "/api/v1/keeper-repos/"

let path_parts rest =
  rest
  |> String.split_on_char '/'
  |> List.filter (fun part -> String.trim part <> "")

let extract_keeper_id path =
  match extract_path_param ~prefix:mapping_prefix path with
  | None | Some "" -> Error "missing keeper id"
  | Some rest -> (
      match path_parts rest with
      | [keeper_id] -> Ok keeper_id
      | [] -> Error "missing keeper id"
      | _ -> Error "expected path /api/v1/keeper-repos/:id")

let mapping_json (m : Repo_manager_types.keeper_repo_mapping) : Yojson.Safe.t =
  let allow_all = List.exists (String.equal "*") m.repository_ids in
  `Assoc
    [
      ("keeper_id", `String m.keeper_id);
      ("keeper_name", `String m.keeper_id);
      ("repositories", `List (List.map (fun s -> `String s) m.repository_ids));
      ("allowed_repos", `List (List.map (fun s -> `String s) m.repository_ids));
      ("allow_all", `Bool allow_all);
    ]

let mapping_of_json keeper_id (json : Yojson.Safe.t) :
    (Repo_manager_types.keeper_repo_mapping, string) result =
  let list_field fields key =
    match List.assoc_opt key fields with
    | Some (`List items) ->
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | `String s :: rest -> loop (s :: acc) rest
          | _ -> Error (Printf.sprintf "field %s must be an array of strings" key)
        in
        loop [] items
    | Some _ -> Error (Printf.sprintf "field %s must be an array of strings" key)
    | None -> Error (Printf.sprintf "missing field %s" key)
  in
  match json with
  | `Assoc fields -> (
      let repository_ids =
        match List.assoc_opt "repositories" fields with
        | Some _ -> list_field fields "repositories"
        | None -> list_field fields "repos"
      in
      match repository_ids with
      | Ok repository_ids -> Ok { Repo_manager_types.keeper_id; repository_ids }
      | Error msg -> Error msg)
  | _ -> Error "expected JSON object body"

let handle_list_mappings state req reqd =
  let base_path = state.Mcp_server.room_config.base_path in
  match Keeper_repo_mapping.load_all ~base_path with
  | Error msg ->
      Http.Response.json ~status:`Internal_server_error ~request:req
        (Yojson.Safe.to_string
           (`Assoc [("ok", `Bool false); ("error", `String msg)]))
        reqd
  | Ok mappings ->
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string
           (`Assoc
             [
               ("mappings", `List (List.map mapping_json mappings));
               ("total", `Int (List.length mappings));
             ]))
        reqd

let handle_get_mapping state keeper_id req reqd =
  let base_path = state.Mcp_server.room_config.base_path in
  match Keeper_repo_mapping.allowed_repositories ~keeper_id ~base_path with
  | Ok repo_ids ->
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string
           (mapping_json { Repo_manager_types.keeper_id; repository_ids = repo_ids }))
        reqd
  | Error _ ->
      (* No mapping is intentionally treated as wildcard access for backward
         compatibility with pre-repository keepers. *)
      Http.Response.json ~compress:true ~request:req
        (Yojson.Safe.to_string
           (mapping_json
              { Repo_manager_types.keeper_id; repository_ids = ["*"] }))
        reqd

let handle_save_mapping state keeper_id req reqd =
  let base_path = state.Mcp_server.room_config.base_path in
  Http.Request.read_body_async reqd (fun body_str ->
      let response status message =
        Http.Response.json ~status ~request:req
          (Yojson.Safe.to_string
             (`Assoc [("ok", `Bool false); ("error", `String message)]))
          reqd
      in
      match Yojson.Safe.from_string body_str with
      | exception Yojson.Json_error msg -> response `Bad_request ("invalid JSON body: " ^ msg)
      | json -> (
          match mapping_of_json keeper_id json with
          | Error msg -> response `Bad_request msg
          | Ok mapping -> (
              match Keeper_repo_mapping.save_mapping ~base_path mapping with
              | Error msg -> response `Bad_request msg
              | Ok () ->
                  Http.Response.json ~request:req
                    (Yojson.Safe.to_string (mapping_json mapping))
                    reqd)))

let add_routes router =
  router
  |> Http.Router.get mappings_path (fun request reqd ->
       with_public_read handle_list_mappings request reqd)
  |> Http.Router.prefix_get mapping_prefix (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           match extract_keeper_id (Http.Request.path req) with
           | Error msg ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc [("ok", `Bool false); ("error", `String msg)]))
                 reqd
           | Ok keeper_id -> handle_get_mapping state keeper_id req reqd)
         request reqd)
  |> Http.Router.prefix_post mapping_prefix (fun request reqd ->
       with_token_permission_auth ~permission:Types.CanAdmin
         (fun state _agent_name req reqd ->
           match extract_keeper_id (Http.Request.path req) with
           | Error msg ->
               Http.Response.json ~status:`Bad_request ~request:req
                 (Yojson.Safe.to_string
                    (`Assoc [("ok", `Bool false); ("error", `String msg)]))
                 reqd
           | Ok keeper_id -> handle_save_mapping state keeper_id req reqd)
         request reqd)
