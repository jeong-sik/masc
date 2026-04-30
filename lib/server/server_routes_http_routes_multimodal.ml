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

(* Tier D3 — server-side filter helpers for /api/v1/multimodal/list.

   Mirrors the client-side filter in [Multimodal_filter_view] so
   F4-driven UI and direct API consumers (curl, scripts) see the
   same matching semantics. The filter operates on the post-
   serialization JSON rather than the typed [Artifact.any]
   existential because [created_by]/metadata-keys access from
   outside the [Multimodal] module would require new accessors;
   the JSON representation already carries every field we need. *)

let lower (s : string) = String.lowercase_ascii s

let case_contains ~(haystack : string) ~(needle : string) : bool =
  if needle = "" then true
  else
    let h = lower haystack in
    let n = lower needle in
    let lh = String.length h in
    let ln = String.length n in
    if ln > lh then false
    else
      let rec loop i =
        if i + ln > lh then false
        else if String.sub h i ln = n then true
        else loop (i + 1)
      in
      loop 0

let json_string_field (json : Yojson.Safe.t) (field : string) : string =
  match Yojson.Safe.Util.member field json with
  | `String s -> s
  | _ -> ""

let json_created_by (json : Yojson.Safe.t) : string =
  match Yojson.Safe.Util.member "provenance" json with
  | `Null -> ""
  | prov -> json_string_field prov "created_by"

let json_metadata_keys (json : Yojson.Safe.t) : string list =
  match Yojson.Safe.Util.member "metadata" json with
  | `Assoc kv -> List.map fst kv
  | _ -> []

let artifact_passes
    ~(kind_filter : string option)
    ~(created_by_filter : string option)
    ~(query : string option)
    (json : Yojson.Safe.t)
    : bool
  =
  let kind_ok =
    match kind_filter with
    | None -> true
    | Some k -> json_string_field json "kind" = k
  in
  let created_by_ok =
    match created_by_filter with
    | None -> true
    | Some cb -> json_created_by json = cb
  in
  let q_ok =
    match query with
    | None -> true
    | Some "" -> true
    | Some q ->
      case_contains ~haystack:(json_string_field json "id") ~needle:q
      || case_contains ~haystack:(json_string_field json "kind") ~needle:q
      || case_contains ~haystack:(json_created_by json) ~needle:q
      || List.exists
           (fun k -> case_contains ~haystack:k ~needle:q)
           (json_metadata_keys json)
  in
  kind_ok && created_by_ok && q_ok

let list_response ?kind_filter ?created_by_filter ?query () =
  let ws = !workspace_getter () in
  let arts = W.all ws in
  let json_arts = List.map A.any_to_json arts in
  let filtered =
    if kind_filter = None && created_by_filter = None && query = None
    then json_arts
    else
      List.filter
        (artifact_passes ~kind_filter ~created_by_filter ~query)
        json_arts
  in
  `Assoc
    [
      ("count", `Int (List.length filtered));
      (* Pre-filter total — lets the F4 client show "N of M". *)
      ("total", `Int (List.length json_arts));
      ("artifacts", `List filtered);
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
             let kind_filter =
               Server_utils.query_param request "kind"
             in
             let created_by_filter =
               Server_utils.query_param request "created_by"
             in
             let query = Server_utils.query_param request "q" in
             let json =
               list_response ?kind_filter ?created_by_filter ?query ()
             in
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
