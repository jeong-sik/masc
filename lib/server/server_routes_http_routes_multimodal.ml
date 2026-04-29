(* Multimodal dashboard HTTP surface — Cycle 27 / Tier D1.
   See server_routes_http_routes_multimodal.mli for design. *)

open Server_utils
open Server_auth
module Http = Http_server_eio
module W = Multimodal.Workspace
module A = Multimodal.Artifact
module Aid = Shared_types.Artifact_id

let workspace_getter : (unit -> W.t) ref = ref (fun () -> W.empty)

let bind_workspace_getter f = workspace_getter := f

let list_response () =
  let ws = !workspace_getter () in
  let arts = W.all ws in
  `Assoc
    [
      ("count", `Int (List.length arts));
      ("artifacts", `List (List.map A.any_to_json arts));
    ]

let parse_id id_str = Aid.of_string id_str

let artifact_response ~id_str =
  let ws = !workspace_getter () in
  match parse_id id_str with
  | Error e ->
      ( `Assoc
          [
            ("error", `String "invalid id");
            ("reason", `String e);
            ("id", `String id_str);
          ],
        `Bad_request )
  | Ok aid -> (
      match W.find_by_id ws aid with
      | None ->
          ( `Assoc
              [
                ("error", `String "not found");
                ("id", `String id_str);
              ],
            `Not_found )
      | Some any -> (A.any_to_json any, `OK))

let aid_list_to_json lst =
  `List (List.map (fun a -> `String (Aid.to_string a)) lst)

let provenance_response ~id_str =
  let ws = !workspace_getter () in
  match parse_id id_str with
  | Error e ->
      ( `Assoc
          [
            ("error", `String "invalid id");
            ("reason", `String e);
            ("id", `String id_str);
          ],
        `Bad_request )
  | Ok aid ->
      let origins = W.origins_of ws aid in
      let descendants = W.descendants_of ws aid in
      ( `Assoc
          [
            ("id", `String id_str);
            ("origins", aid_list_to_json origins);
            ("descendants", aid_list_to_json descendants);
          ],
        `OK )

let add_routes router =
  router
  |> Http.Router.prefix_get "/api/v1/multimodal/list"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let json = list_response () in
             respond_public_read_json ~status:`OK request reqd
               (Yojson.Safe.to_string json))
           request reqd)
  |> Http.Router.prefix_get "/api/v1/multimodal/get/"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let path = Http.Request.path request in
             match
               extract_path_param
                 ~prefix:"/api/v1/multimodal/get/" path
             with
             | None ->
                 respond_public_read_json ~status:`Bad_request
                   request reqd
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ("error", `String "id required");
                        ]))
             | Some id_str ->
                 let json, status =
                   artifact_response ~id_str
                 in
                 respond_public_read_json ~status request reqd
                   (Yojson.Safe.to_string json))
           request reqd)
  |> Http.Router.prefix_get "/api/v1/multimodal/provenance/"
       (fun request reqd ->
         with_public_read
           (fun _state _req reqd ->
             let path = Http.Request.path request in
             match
               extract_path_param
                 ~prefix:"/api/v1/multimodal/provenance/" path
             with
             | None ->
                 respond_public_read_json ~status:`Bad_request
                   request reqd
                   (Yojson.Safe.to_string
                      (`Assoc
                        [
                          ("error", `String "id required");
                        ]))
             | Some id_str ->
                 let json, status =
                   provenance_response ~id_str
                 in
                 respond_public_read_json ~status request reqd
                   (Yojson.Safe.to_string json))
           request reqd)
