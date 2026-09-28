(* HTTP trigger layer for collab host sessions (RFC-0471 stack 5).

   POST /api/v1/collab/host — {keeper, base_url?}: start sharing the
     keeper (or resume its live room) and answer the share links.
   POST /api/v1/collab/stop — {keeper}: stop the keeper's live rooms.

   Writes need CanAdmin, like the preset routes. [base_url] is the
   public relay address guests dial (self-hosted: the operator's own
   host); when omitted the request authority is used, which serves
   loopback guests and local testing. *)

open Server_auth
module Http = Http_server_eio

let base_path_of state = (Mcp_server.workspace_config state).Workspace.base_path

type host_request = {
  keeper : string;
  base_url : string option;
}

let object_of_body body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> Ok fields
  | _ -> Error "body must be a JSON object"
  | exception Yojson.Json_error message -> Error ("invalid JSON: " ^ message)
;;

let keeper_field fields =
  match List.assoc_opt "keeper" fields with
  | Some (`String raw) ->
    let keeper = String.trim raw in
    if String.equal keeper ""
    then Error "keeper must not be blank"
    else Ok keeper
  | Some _ -> Error "keeper must be a string"
  | None -> Error "keeper missing"
;;

(** Exposed for tests: [{keeper, base_url?}] with a non-blank keeper. *)
let decode_host_request body =
  match object_of_body body with
  | Error _ as error -> error
  | Ok fields -> (
    match keeper_field fields with
    | Error _ as error -> error
    | Ok keeper -> (
      match List.assoc_opt "base_url" fields with
      | None | Some `Null -> Ok { keeper; base_url = None }
      | Some (`String raw) ->
        let trimmed = String.trim raw in
        if String.equal trimmed ""
        then Ok { keeper; base_url = None }
        else Ok { keeper; base_url = Some trimmed }
      | Some _ -> Error "base_url must be a string"))
;;

let decode_stop_request body =
  match object_of_body body with
  | Error _ as error -> error
  | Ok fields -> keeper_field fields
;;

let ok_json fields : Yojson.Safe.t = `Assoc (("ok", `Bool true) :: fields)
let error_json message : Yojson.Safe.t = `Assoc [ "ok", `Bool false; "error", `String message ]

(* A base URL is an origin and nothing else: an http(s) scheme, a host,
   an optional port. Paths, queries, fragments and userinfo are refused
   rather than stripped — silently rewriting the operator's address
   mints links to a place they did not name. *)
let validate_base_url raw =
  let trimmed = String.trim raw in
  if String.equal trimmed ""
     || String.contains trimmed ' '
     || String.contains trimmed '\t'
     || String.contains trimmed '\n'
  then Error "base_url must be an http(s) URL"
  else (
    let uri = Uri.of_string trimmed in
    match
      ( Uri.scheme uri |> Option.map String.lowercase_ascii,
        Uri.userinfo uri,
        Uri.host uri,
        Uri.port uri,
        Uri.path uri,
        Uri.query uri,
        Uri.fragment uri )
    with
    | Some ("http" | "https" as scheme), None, Some host, port, path, [], None
      when (not (String.equal host "")) && (String.equal path "" || String.equal path "/") -> (
      match port with
      | Some p when p < 1 || p > 65535 -> Error "base_url port out of range"
      | _ ->
        let rendered_host =
          match Ipaddr.V6.of_string host with
          | Ok _ -> "[" ^ host ^ "]"
          | Error _ -> host
        in
        let rendered_port =
          match port with
          | None -> ""
          | Some p -> Printf.sprintf ":%d" p
        in
        Ok (Printf.sprintf "%s://%s%s" scheme rendered_host rendered_port))
    | _ -> Error "base_url must be an http(s) URL with no path, query, or userinfo")
;;

let authority_base_url ~default_port =
  let authority = Server_request_authority.current_exn () in
  let host = Server_request_authority.host authority in
  let port =
    Option.value
      ~default:default_port
      (Server_request_authority.port authority)
  in
  let rendered_host =
    match Ipaddr.V6.of_string host with
    | Ok _ -> "[" ^ host ^ "]"
    | Error _ -> host
  in
  Printf.sprintf "http://%s:%d" rendered_host port
;;

let room_b64 room_id =
  Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet room_id
;;

let session_json ~base_url ~resumed session =
  let room = Server_collab_host.session_room session in
  ok_json
    [ "keeper", `String (Server_collab_host.session_keeper session)
    ; "room_id", `String (room_b64 room.Collab_link.id)
    ; "view_link", `String (Collab_link.format_link room Collab_link.View)
    ; "control_link", `String (Collab_link.format_link room Collab_link.Control)
    ; "web_link", `String (Collab_link.format_web_link ~base:base_url room Collab_link.View)
    ; "control_web_link", `String (Collab_link.format_web_link ~base:base_url room Collab_link.Control)
    ; "base_url", `String base_url
    ; "resumed", `Bool resumed
    ]
;;

(* A 128-bit id collision retries with a fresh mint; three in a row is
   not luck anymore. *)
let rec start_session ~sw ~base_dir ~keeper retries =
  match Server_collab_host.start ~sw ~base_dir ~keeper () with
  | Ok _ as ok -> ok
  | Error Server_collab_host.Room_conflict when retries > 0 ->
    start_session ~sw ~base_dir ~keeper (retries - 1)
  | Error _ as error -> error
;;

let keeper_exists state keeper_name =
  Keeper_status_detail.keeper_exists_config
    ~config:(Mcp_server.workspace_config state)
    keeper_name
;;

let add_routes ~sw ~port router =
  router
  |> Http.Router.post "/api/v1/collab/host" (fun request reqd ->
       with_permission_auth
         ~permission:Masc_domain.CanAdmin
         (fun state _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
               match decode_host_request body with
               | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd
                   (error_json message)
               | Ok { keeper; base_url } -> (
                 let base_url =
                   match base_url with
                   | Some raw -> validate_base_url raw
                   | None -> Ok (authority_base_url ~default_port:port)
                 in
                 match base_url with
                 | Error message ->
                   respond_json_value_with_cors ~status:`Bad_request request reqd
                     (error_json message)
                 | Ok base_url -> (
                   match keeper_exists state keeper with
                   | Error detail ->
                     Log.Pages.error "collab host %s: keeper lookup failed: %s" keeper detail;
                     respond_json_value_with_cors ~status:`Internal_server_error
                       request reqd (error_json "keeper lookup failed")
                   | Ok false ->
                     respond_json_value_with_cors ~status:`Not_found request reqd
                       (error_json ("unknown keeper: " ^ keeper))
                   | Ok true -> (
                     match Server_collab_host.live_for_keeper keeper with
                     | session :: _ ->
                       respond_json_value_with_cors request reqd
                         (session_json ~base_url ~resumed:true session)
                     | [] -> (
                       match
                         start_session ~sw ~base_dir:(base_path_of state) ~keeper 3
                       with
                       | Ok session ->
                         respond_json_value_with_cors request reqd
                           (session_json ~base_url ~resumed:false session)
                       | Error Server_collab_host.Room_conflict ->
                         respond_json_value_with_cors
                           ~status:`Service_unavailable request reqd
                           (error_json "room id collision; retry")
                       | Error Server_collab_host.Seal_key_rejected ->
                         Log.Pages.error "collab host %s: minted seal key rejected" keeper;
                         respond_json_value_with_cors ~status:`Internal_server_error
                           request reqd (error_json "could not start sharing")))))))
         request
         reqd)
  |> Http.Router.post "/api/v1/collab/stop" (fun request reqd ->
       with_permission_auth
         ~permission:Masc_domain.CanAdmin
         (fun state _req reqd ->
           Http.Request.read_body_async reqd (fun body ->
               match decode_stop_request body with
               | Error message ->
                 respond_json_value_with_cors ~status:`Bad_request request reqd
                   (error_json message)
               | Ok keeper ->
                 let sessions = Server_collab_host.live_for_keeper keeper in
                 List.iter Server_collab_host.stop sessions;
                 respond_json_value_with_cors request reqd
                   (ok_json
                      [ "keeper", `String keeper
                      ; "stopped", `Int (List.length sessions)
                      ])))
         request
         reqd)
;;
