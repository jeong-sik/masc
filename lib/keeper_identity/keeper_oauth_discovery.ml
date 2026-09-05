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
}

type get = url:string -> (int * string, string) result

let discovery_headers =
  [ "User-Agent", "masc/0.31.0"
  ; "Accept", "application/json, */*"
  ]

let default_get ~url = Masc_http_client.get_sync ~url ~headers:discovery_headers ()

type ask = url:string -> (string * string) list option

let default_ask ~url =
  match Masc_http_client.get_response_sync ~url ~headers:discovery_headers () with
  | Error _ -> None
  | Ok response -> Some response.Masc_http_client.headers

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

(* RFC 9728 §3 root fallback: if path-scoped metadata endpoint returns 404,
   clients should retry at server origin root:
   https://host/.well-known/<segment> *)
let root_well_known_url ~segment url =
  let uri = Uri.of_string url in
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some _ ->
    let origin = Uri.with_path (Uri.with_query uri []) "" in
    Ok (Printf.sprintf "%s/.well-known/%s" (Uri.to_string origin) segment)
  | _ -> Error (Bad_mcp_url url)

(* RFC 9728 5.1: a protected resource answers an unauthenticated request
   with a WWW-Authenticate header naming where its metadata is:

     Bearer resource_metadata="https://host/.well-known/...", error="..."

   Only the quoted form is read. The grammar allows a bare token and no
   server measured uses one; reading it would mean guessing where the value
   ends among the other parameters, which is a worse failure than not
   reading it at all.

   A plaintext location is dropped rather than followed: the answer decides
   where a token comes from, and one fetched over http could be replaced on
   the way. *)
let extract_resource_metadata value =
  let key = "resource_metadata=\"" in
  let rec after at =
    if at + String.length key > String.length value then None
    else if String.equal (String.sub value at (String.length key)) key
    then Some (at + String.length key)
    else after (at + 1)
  in
  match after 0 with
  | None -> None
  | Some start ->
    (match String.index_from_opt value start '"' with
     | None -> None
     | Some stop ->
       let found = String.sub value start (stop - start) in
       if String.starts_with ~prefix:"https://" found then Some found
       else None)

let resource_metadata_of_headers headers =
  List.find_map
    (fun (name, value) ->
      if String.equal (String.lowercase_ascii name) "www-authenticate"
      then extract_resource_metadata value
      else None)
    headers

(* RFC 8414 3.1: a terminating "/" in the issuer is removed before the
   well-known segment goes in. Every Google Workspace MCP server names its
   authorization server as "https://accounts.google.com/", and the URL built
   with that slash left on answers 404 while the one without answers 200 --
   so this is the difference between reaching Google at all and not.

   Only the issuer. A protected resource keeps the path it was given:
   GitHub's names its metadata under "/mcp/" and serves it there. *)
let issuer_for_well_known issuer =
  let length = String.length issuer in
  if length > 1 && String.ends_with ~suffix:"/" issuer
  then String.sub issuer 0 (length - 1)
  else issuer

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

let require ~url ~key value =
  match value with
  | Some value -> Ok value
  | None ->
    Error (Malformed { url; detail = Printf.sprintf "no %s" key })

let fetch_with_root_fallback ~get ~url ~segment ~base_url =
  match fetch_json ~get ~url with
  | Ok pairs -> Ok pairs
  | Error (Not_published _ as not_pub) ->
    let orig_error = Error not_pub in
    (match root_well_known_url ~segment base_url with
     | Error _ -> orig_error
     | Ok root_url ->
       if String.equal root_url url then orig_error
       else
         (match fetch_json ~get ~url:root_url with
          | Ok pairs -> Ok pairs
          | Error (Not_published _ | Transport _ | Malformed _
                 | Bad_mcp_url _ | No_authorization_server _) ->
            orig_error))
  | Error (Bad_mcp_url _ as err) -> Error err
  | Error (Transport _ as err) -> Error err
  | Error (Malformed _ as err) -> Error err
  | Error (No_authorization_server _ as err) -> Error err

let discover ?(get = default_get) ?(ask = default_ask) ~mcp_url () =
  (* Asked before computed. Of 41 live MCP servers measured on 2026-08-27,
     eleven name a location the computed URL does not reach -- they publish
     at the origin while serving MCP below it -- and nine send no such
     header, so neither route alone reaches every server. Where a server
     answers, its answer is taken as it stands: every one measured returned
     a usable document, and trying a second location after the server has
     said which one is its own would be this code overruling it. *)
  let* computed =
    well_known_url ~segment:"oauth-protected-resource" mcp_url
  in
  let resource_url =
    match ask ~url:mcp_url with
    | None -> computed
    | Some headers ->
      Option.value (resource_metadata_of_headers headers) ~default:computed
  in
  let* resource_pairs =
    fetch_with_root_fallback ~get ~url:resource_url
      ~segment:"oauth-protected-resource" ~base_url:mcp_url
  in
  let resource =
    Option.value (string_member resource_pairs "resource") ~default:mcp_url
  in
  let* issuer =
    match string_list_member resource_pairs "authorization_servers" with
    | issuer :: _ -> Ok issuer
    | [] -> Error (No_authorization_server resource)
  in
  let cleaned_issuer = issuer_for_well_known issuer in
  let* server_url =
    well_known_url ~segment:"oauth-authorization-server" cleaned_issuer
  in
  let* server_pairs =
    fetch_with_root_fallback ~get ~url:server_url
      ~segment:"oauth-authorization-server" ~base_url:cleaned_issuer
  in
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
    }
