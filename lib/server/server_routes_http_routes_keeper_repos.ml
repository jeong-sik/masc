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
  let allow_all =
    match m.repository_scope with
    | Repo_manager_types.All_repositories -> true
    | Repo_manager_types.Selected_repositories _ -> false
  in
  `Assoc
    [
      ("keeper_id", `String m.keeper_id);
      ("keeper_name", `String m.keeper_id);
      ("repositories", `List (List.map (fun s -> `String s) m.repository_ids));
      ("allowed_repos", `List (List.map (fun s -> `String s) m.repository_ids));
      ("allow_all", `Bool allow_all);
      ("policy_mode", `String "advisory");
      ("access_cap", `Bool false);
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
      | Ok repository_ids ->
          Ok
            (Repo_manager_types.make_keeper_repo_mapping ~keeper_id
               ~repository_ids)
      | Error msg -> Error msg)
  | _ -> Error "expected JSON object body"

let handle_list_mappings state req reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  match Keeper_repo_mapping.load_all ~base_path with
  | Error msg ->
      Http.Response.json_value ~status:`Internal_server_error ~request:req
        (`Assoc [("ok", `Bool false); ("error", `String msg)])
        reqd
  | Ok mappings ->
      Http.Response.json_value ~compress:true ~request:req
        (`Assoc
           [
             ("mappings", `List (List.map mapping_json mappings));
             ("total", `Int (List.length mappings));
           ])
        reqd

let handle_get_mapping state keeper_id req reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  match Keeper_repo_mapping.load_all ~base_path with
  | Error msg ->
      Http.Response.json_value ~status:`Internal_server_error ~request:req
        (`Assoc [("ok", `Bool false); ("error", `String msg)])
        reqd
  | Ok mappings -> (
      match
        List.find_opt
          (fun (m : Repo_manager_types.keeper_repo_mapping) ->
            String.equal m.keeper_id keeper_id)
          mappings
      with
      | Some mapping ->
          Http.Response.json_value ~compress:true ~request:req
            (mapping_json mapping) reqd
      | None ->
          Http.Response.json_value ~status:`Not_found ~request:req
            (`Assoc
               [
                 ("ok", `Bool false);
                 ( "error",
                   `String
                     (Printf.sprintf "No mapping found for keeper: %s" keeper_id)
                 );
               ])
            reqd)

let handle_save_mapping state keeper_id req reqd =
  let base_path = (Mcp_server.workspace_config state).base_path in
  Http.Request.read_body_async reqd (fun body_str ->
      let response status message =
        Http.Response.json_value ~status ~request:req
          (`Assoc [("ok", `Bool false); ("error", `String message)])
          reqd
      in
      match Yojson.Safe.from_string body_str with
      | exception Yojson.Json_error msg -> response `Bad_request ("invalid JSON body: " ^ msg)
      | json -> (
          match mapping_of_json keeper_id json with
          | Error msg -> response `Bad_request msg
          | Ok mapping -> (
              match Keeper_repo_mapping.save_mapping_eio ~base_path mapping with
              | Error msg -> response `Bad_request msg
              | Ok () ->
                  Http.Response.json_value ~request:req
                    (mapping_json mapping) reqd)))

let add_routes router =
  router
  |> Http.Router.get mappings_path (fun request reqd ->
       with_public_read handle_list_mappings request reqd)
  |> Http.Router.prefix_get mapping_prefix (fun request reqd ->
       with_public_read
         (fun state req reqd ->
           match extract_keeper_id (Http.Request.path req) with
           | Error msg ->
               Http.Response.json_value ~status:`Bad_request ~request:req
                 (`Assoc [("ok", `Bool false); ("error", `String msg)])
                 reqd
           | Ok keeper_id -> handle_get_mapping state keeper_id req reqd)
         request reqd)
  |> Http.Router.prefix_post mapping_prefix (fun request reqd ->
       with_token_permission_auth ~permission:Masc_domain.CanAdmin
         (fun state _agent_name req reqd ->
           match extract_keeper_id (Http.Request.path req) with
           | Error msg ->
               Http.Response.json_value ~status:`Bad_request ~request:req
                 (`Assoc [("ok", `Bool false); ("error", `String msg)])
                 reqd
           | Ok keeper_id -> handle_save_mapping state keeper_id req reqd)
         request reqd)
