(** See keeper_oauth_discovery.mli. Two public hops, no credential involved:
    this runs before anyone has one. *)

type error =
  | Bad_mcp_url of string
  | Transport of { url : string; detail : string }
  | Not_published of { url : string; status : int }
  | Malformed of { url : string; detail : string }
  | No_authorization_server of string

let error_to_string = function
  | Bad_mcp_url url -> Printf.sprintf "%S is not an https URL with a host" url
  | Transport { url; detail } ->
    Printf.sprintf "could not reach %s: %s" url detail
  | Not_published { url; status } ->
    Printf.sprintf "%s answered %d; this server publishes no such metadata" url
      status
  | Malformed { url; detail } ->
    Printf.sprintf "%s answered with something unreadable: %s" url detail
  | No_authorization_server resource ->
    Printf.sprintf
      "%s published its metadata but named no authorization server" resource

type t = {
  resource : string;
  issuer : string;
  authorize_url : string;
  token_url : string;
  registration_url : string option;
  scopes_supported : string list;
  supports_pkce_s256 : bool;
  client_secret_optional : bool;
}

type get = url:string -> (int * string, string) result

let default_get ~url = Masc_http_client.get_sync ~url ~headers:[] ()

let ( let* ) = Result.bind

(* RFC 9728 puts the well-known segment between the origin and the resource
   path, not after it: the metadata for https://host/a/b lives at
   https://host/.well-known/oauth-protected-resource/a/b. Appending instead
   happens to work on some servers, which is exactly why it is worth being
   deliberate here rather than discovering the difference on the one that
   does not. *)
let well_known_url ~segment url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some _ ->
    let path = Uri.path uri in
    let origin = Uri.with_path (Uri.with_query uri []) "" in
    Ok (Printf.sprintf "%s/.well-known/%s%s" (Uri.to_string origin) segment path)
  | _ -> Error (Bad_mcp_url url)

let fetch_json ~get ~url =
  match get ~url with
  | Error detail -> Error (Transport { url; detail })
  | Ok (status, _) when status < 200 || status >= 300 ->
    Error (Not_published { url; status })
  | Ok (_, body) ->
    (match Yojson.Safe.from_string body with
     | exception Yojson.Json_error detail -> Error (Malformed { url; detail })
     | `Assoc pairs -> Ok pairs
     | _ -> Error (Malformed { url; detail = "the answer is not an object" }))

let string_member pairs key =
  match List.assoc_opt key pairs with
  | Some (`String value) when String.trim value <> "" -> Some value
  | Some _ | None -> None

let string_list_member pairs key =
  match List.assoc_opt key pairs with
  | Some (`List items) ->
    List.filter_map (function `String value -> Some value | _ -> None) items
  | Some _ | None -> []

let bool_member pairs key =
  match List.assoc_opt key pairs with
  | Some (`Bool value) -> value
  | Some _ | None -> false

let require ~url ~key value =
  match value with
  | Some value -> Ok value
  | None ->
    Error (Malformed { url; detail = Printf.sprintf "no %s" key })

let discover ?(get = default_get) ~mcp_url () =
  let* resource_url =
    well_known_url ~segment:"oauth-protected-resource" mcp_url
  in
  let* resource_pairs = fetch_json ~get ~url:resource_url in
  let resource =
    Option.value (string_member resource_pairs "resource") ~default:mcp_url
  in
  let* issuer =
    match string_list_member resource_pairs "authorization_servers" with
    | issuer :: _ -> Ok issuer
    | [] -> Error (No_authorization_server resource)
  in
  let* server_url =
    well_known_url ~segment:"oauth-authorization-server" issuer
  in
  let* server_pairs = fetch_json ~get ~url:server_url in
  let* authorize_url =
    require ~url:server_url ~key:"authorization_endpoint"
      (string_member server_pairs "authorization_endpoint")
  in
  let* token_url =
    require ~url:server_url ~key:"token_endpoint"
      (string_member server_pairs "token_endpoint")
  in
  Ok
    { resource
    ; issuer
    ; authorize_url
    ; token_url
    ; registration_url = string_member server_pairs "registration_endpoint"
    ; scopes_supported = string_list_member resource_pairs "scopes_supported"
    ; supports_pkce_s256 =
        List.mem "S256"
          (string_list_member server_pairs "code_challenge_methods_supported")
    ; client_secret_optional =
        List.mem "none"
          (string_list_member server_pairs
             "token_endpoint_auth_methods_supported")
        || bool_member server_pairs "client_id_metadata_document_supported"
    }
