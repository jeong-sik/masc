(* HIGH-RISK-UNREVIEWED: OAuth client identification from a fetched document.
   Human security review is required before this marker may be removed. *)

let ( let* ) = Result.bind

type document_url = string

type client_id =
  | Registered of string
  | Document of document_url

let is_https uri =
  match Uri.scheme uri with
  | Some scheme -> String.equal (String.lowercase_ascii scheme) "https"
  | None -> false
;;

(* The installed uri decodes "%2E" in Uri.path, but whether it does is the
   library's choice, so the encoded spellings are refused as well. *)
let is_dot_segment segment =
  match String.lowercase_ascii segment with
  | "." | ".." | "%2e" | "%2e%2e" | ".%2e" | "%2e." -> true
  | _ -> false
;;

let document_url_rule_broken uri =
  let path = Uri.path uri in
  match Uri.host uri with
  | None | Some "" -> Some "client_id URL has no host"
  | Some _ when Option.is_some (Uri.userinfo uri) ->
    Some "client_id URL must not carry userinfo"
  | Some _ when Option.is_some (Uri.fragment uri) ->
    Some "client_id URL must not carry a fragment"
  | Some _ when Option.is_some (Uri.verbatim_query uri) ->
    Some "client_id URL must not carry a query"
  | Some _ when String.equal path "" || String.equal path "/" ->
    Some "client_id URL has no path"
  | Some _ when List.exists is_dot_segment (String.split_on_char '/' path) ->
    Some "client_id URL must not contain dot segments"
  | Some _ -> None
;;

(* C0 controls and DEL, and C1 controls (U+0080..U+009F, UTF-8 C2 80..C2 9F):
   a terminal reads either as a command, so a name a client chose must not
   carry them to the operator's screen. *)
let has_control_character value =
  let length = String.length value in
  let rec scan index =
    if index >= length
    then false
    else
      let byte = Char.code value.[index] in
      if byte < 0x20 || byte = 0x7f
      then true
      else if
        byte = 0xc2
        && index + 1 < length
        && Char.code value.[index + 1] >= 0x80
        && Char.code value.[index + 1] <= 0x9f
      then true
      else scan (index + 1)
  in
  scan 0
;;

(* ocaml-uri parses leniently: it stops at a line feed, ends the authority at
   a backslash, and reads "host:abc" as a path. A string it would print back
   differently is not the URL that gets fetched or redirected to. *)
let is_plain_url_text raw =
  String.for_all (fun c -> c > ' ' && c <> '\127' && c <> '\\') raw
  && String.equal (Uri.to_string (Uri.of_string raw)) raw
;;

let classify_client_id raw =
  let uri = Uri.of_string raw in
  if not (is_https uri)
  then Ok (Registered raw)
  else if not (is_plain_url_text raw)
  then Error "client_id URL is not plain URL text"
  else
    match document_url_rule_broken uri with
    | Some rule -> Error rule
    | None -> Ok (Document raw)
;;

let max_document_bytes = 5 * 1024

type document =
  { client_id : document_url
  ; client_name : string
  ; redirect_uris : string list
  }

let supported_grant_types = [ "authorization_code"; "refresh_token" ]
let supported_response_types = [ "code" ]

let rec has_repeated_name = function
  | [] -> false
  | (name, _) :: rest -> List.mem_assoc name rest || has_repeated_name rest
;;


let required_string fields name =
  match List.assoc_opt name fields with
  | Some (`String value) when not (String.equal (String.trim value) "") -> Ok value
  | Some (`String _) -> Error (name ^ " is blank")
  | Some _ -> Error (name ^ " must be a string")
  | None -> Error (name ^ " is required")
;;

let string_array fields name =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`List values) ->
    let rec collect acc = function
      | [] -> Ok (Some (List.rev acc))
      | `String value :: rest -> collect (value :: acc) rest
      | _ :: _ -> Error (name ^ " must contain only strings")
    in
    collect [] values
  | Some _ -> Error (name ^ " must be an array")
;;

let has_duplicate values =
  List.length values <> List.length (List.sort_uniq String.compare values)
;;

let within name supported fields =
  let* values = string_array fields name in
  match values with
  | None -> Ok ()
  | Some values when has_duplicate values -> Error (name ^ " contains a duplicate")
  | Some values when List.for_all (fun value -> List.mem value supported) values ->
    Ok ()
  | Some _ -> Error (name ^ " contains a value this server does not support")
;;

let public_client fields =
  match List.assoc_opt "token_endpoint_auth_method" fields with
  | None | Some (`String "none") -> Ok ()
  | Some _ -> Error "token_endpoint_auth_method must be none"
;;

let no_shared_secret fields =
  if List.mem_assoc "client_secret" fields
     || List.mem_assoc "client_secret_expires_at" fields
  then Error "a client metadata document must not carry a client secret"
  else Ok ()
;;

let parse_document url body =
  if String.length body > max_document_bytes
  then Error (Printf.sprintf "document is larger than %d bytes" max_document_bytes)
  else
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error _ -> Error "document is not JSON"
    | `Assoc fields when has_repeated_name fields ->
      Error "document repeats a member name"
    | `Assoc fields ->
      let* client_id = required_string fields "client_id" in
      if not (String.equal client_id url)
      then Error "client_id does not equal the document URL"
      else
        let* client_name = required_string fields "client_name" in
        let* () =
          if has_control_character client_name
          then Error "client_name contains a control character"
          else Ok ()
        in
        let* redirect_uris = string_array fields "redirect_uris" in
        let* redirect_uris =
          match redirect_uris with
          | None | Some [] -> Error "redirect_uris must list at least one URI"
          | Some uris when has_duplicate uris -> Error "redirect_uris contains a duplicate"
          | Some uris -> Ok uris
        in
        let* () = no_shared_secret fields in
        let* () = public_client fields in
        let* () = within "grant_types" supported_grant_types fields in
        let* () = within "response_types" supported_response_types fields in
        Ok { client_id = url; client_name; redirect_uris }
    | _ -> Error "document is not a JSON object"
;;

let is_loopback_http uri =
  (match Uri.scheme uri with
   | Some scheme -> String.equal (String.lowercase_ascii scheme) "http"
   | None -> false)
  && Masc_network_defaults.is_loopback_host_opt (Uri.host uri)
  && Option.is_none (Uri.userinfo uri)
  && Option.is_none (Uri.fragment uri)
;;

let same_loopback_target ~listed ~requested =
  let listed = Uri.of_string listed in
  let requested = Uri.of_string requested in
  is_loopback_http listed
  && is_loopback_http requested
  && Option.equal
       String.equal
       (Option.map String.lowercase_ascii (Uri.host listed))
       (Option.map String.lowercase_ascii (Uri.host requested))
  && String.equal (Uri.path listed) (Uri.path requested)
  && Option.equal String.equal (Uri.verbatim_query listed) (Uri.verbatim_query requested)
;;

let redirect_uri_allowed document requested =
  is_plain_url_text requested
  && List.exists
    (fun listed ->
      String.equal listed requested || same_loopback_target ~listed ~requested)
    document.redirect_uris
;;
