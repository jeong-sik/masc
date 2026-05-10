(** Server IDE HTTP — REST endpoints for observational IDE annotations
    and code regions.

    Reads/writes are scoped to the workspace base resolved by
    {!Server_routes_http_routes_workspace.classify_workspace_query}. *)

open Server_auth
open Server_utils

module Http = Http_server_eio

let base_path_of_state state = state.Mcp_server.room_config.base_path

let resolve_workspace_base ~state ~uri =
  let project_base = base_path_of_state state in
  let config = state.Mcp_server.room_config in
  let lookup_repository repo_id =
    match Repo_store.find ~base_path:project_base repo_id with
    | Ok repo -> Some (Repo_store.local_path ~base_path:project_base repo)
    | Error _ -> None
  in
  let lookup_playground name =
    match Keeper_types.read_meta config name with
    | Ok (Some m) -> Some (Keeper_sandbox.host_root_abs_of_meta ~config m)
    | _ -> None
  in
  let exists_dir p = Sys.file_exists p && Sys.is_directory p in
  Server_routes_http_routes_workspace.classify_workspace_query
    ~project_base
    ~lookup_repository
    ~lookup_playground
    ~exists_dir
    ~repo_param:(Uri.get_query_param uri "repo_id")
    ~keeper_param:(Uri.get_query_param uri "keeper")

let json_error message =
  `Assoc [("ok", `Bool false); ("error", `String message)]

let json_ok data =
  `Assoc [("ok", `Bool true); ("data", data)]

let add_routes router =
  let router1 =
    Http.Router.get "/api/v1/ide/annotations" (fun request reqd ->
      with_public_read
        (fun state _req reqd ->
          let uri = Uri.of_string request.target in
          let base, _source = resolve_workspace_base ~state ~uri in
          let file_path =
            match Uri.get_query_param uri "file_path" with
            | Some p when p <> "" -> Some p
            | _ -> None
          in
          let keeper_id =
            match Uri.get_query_param uri "keeper_id" with
            | Some k when k <> "" -> Some k
            | _ -> None
          in
          let goal_id =
            match Uri.get_query_param uri "goal_id" with
            | Some g when g <> "" -> Some g
            | _ -> None
          in
          let filter = { Ide_annotation_types.file_path; keeper_id; goal_id } in
          let annotations = Ide_annotations.list ~base_dir:base ~filter in
          let json = `List (List.map Ide_annotation_types.annotation_to_json annotations) in
          Http.Response.json ~compress:true ~request:request
            (Yojson.Safe.to_string (json_ok json)) reqd)
        request reqd)
    router
  in
  let router2 =
    Http.Router.post "/api/v1/ide/annotations" (fun request reqd ->
      with_public_read
        (fun state req reqd ->
          let uri = Uri.of_string request.target in
          let base, _source = resolve_workspace_base ~state ~uri in
          Http.Request.read_body_async reqd (fun body_str ->
            let json =
              try Yojson.Safe.from_string body_str
              with _ -> `Assoc []
            in
            let find_string key =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt key fields with
                  | Some (`String s) when s <> "" -> Some s
                  | _ -> None)
              | _ -> None
            in
            let find_int key =
              match json with
              | `Assoc fields -> (
                  match List.assoc_opt key fields with
                  | Some (`Int i) -> Some i
                  | Some (`Intlit s) -> int_of_string_opt s
                  | _ -> None)
              | _ -> None
            in
            match
              ( find_string "file_path",
                find_int "line_start",
                find_int "line_end",
                find_string "keeper_id",
                find_string "content" )
            with
            | Some file_path, Some line_start, Some line_end, Some keeper_id, Some content ->
                let kind_str = Option.value (find_string "kind") ~default:"Comment" in
                let kind = Ide_annotations.annotation_kind_of_string kind_str in
                let goal_id = find_string "goal_id" in
                let task_id = find_string "task_id" in
                (match
                   Ide_annotations.create ~base_dir:base ~keeper_id ~file_path
                     ~line_start ~line_end ~kind ~content ?goal_id ?task_id ()
                 with
                 | Ok annotation ->
                     Http.Response.json ~status:`Created ~request:request
                       (Yojson.Safe.to_string
                          (json_ok (Ide_annotation_types.annotation_to_json annotation)))
                       reqd
                 | Error msg ->
                     Http.Response.json ~status:`Bad_request ~request:request
                       (Yojson.Safe.to_string (json_error msg)) reqd)
            | _ ->
                Http.Response.json ~status:`Bad_request ~request:request
                  (Yojson.Safe.to_string (json_error "Missing required fields"))
                  reqd))
        request reqd)
    router1
  in
  let router3 =
    Http.Router.delete "/api/v1/ide/annotations/:id" (fun request reqd ->
      with_public_read
        (fun state _req reqd ->
          let uri = Uri.of_string request.target in
          let base, _source = resolve_workspace_base ~state ~uri in
          let id =
            match Http.Router.param request "id" with
            | Some s when s <> "" -> s
            | _ -> ""
          in
          let keeper_id =
            match Uri.get_query_param uri "keeper_id" with
            | Some k when k <> "" -> k
            | _ -> ""
          in
          if id = "" || keeper_id = "" then
            Http.Response.json ~status:`Bad_request ~request:request
              (Yojson.Safe.to_string (json_error "Missing id or keeper_id"))
              reqd
          else
            match Ide_annotations.delete ~base_dir:base ~id ~keeper_id with
            | Ok () ->
                Http.Response.json ~status:`No_content ~request:request "{}" reqd
            | Error msg ->
                Http.Response.json ~status:`Forbidden ~request:request
                  (Yojson.Safe.to_string (json_error msg)) reqd)
        request reqd)
    router2
  in
  Http.Router.get "/api/v1/ide/regions" (fun request reqd ->
    with_public_read
      (fun state _req reqd ->
        let uri = Uri.of_string request.target in
        let base, _source = resolve_workspace_base ~state ~uri in
        let file_path =
          match Uri.get_query_param uri "file_path" with
          | Some p when p <> "" -> p
          | _ -> ""
        in
        let store_dir = Filename.concat base ".masc-ide" in
        let path = Filename.concat store_dir "regions.jsonl" in
        let raw =
          if not (Sys.file_exists path) then []
          else Fs_compat.load_jsonl path
        in
        let regions =
          List.filter_map
            (fun j ->
              match Ide_annotation_types.region_of_json j with
              | Ok r when file_path = "" || r.file_path = file_path -> Some r
              | _ -> None)
            raw
        in
        let json = `List (List.map Ide_annotation_types.region_to_json regions) in
        Http.Response.json ~compress:true ~request:request
          (Yojson.Safe.to_string (json_ok json)) reqd)
      request reqd)
    router3
