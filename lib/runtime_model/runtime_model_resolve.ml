(** Explicit model selector and custom endpoint parsing. *)

type model_selector =
  | Concrete of string
  | Auto

let model_selector_of_string s =
  if String.equal (String.lowercase_ascii (String.trim s)) "auto"
  then Auto
  else Concrete s
;;

type custom_model_error =
  | Missing_endpoint
  | Empty_model
  | Invalid_endpoint

let custom_model_error_to_string = function
  | Missing_endpoint -> "custom model requires an explicit model@url selection"
  | Empty_model -> "custom model selection has an empty model id"
  | Invalid_endpoint -> "custom model requires an absolute HTTP(S) endpoint"
;;

(* Uri's public grammar consumes a numeric port even when its int conversion
   overflows to None. Check that protocol component against the raw authority
   so an explicit port can never silently become a scheme-default destination.
   Full URI syntax is validated by Uri.Parser before this check. *)
let endpoint_authority_is_lossless url uri =
  match String.index_opt url ':' with
  | None -> false
  | Some scheme_end ->
    let start = scheme_end + 3 in
    let rec authority_end offset =
      if offset = String.length url then offset
      else match url.[offset] with
        | '/' | '?' | '#' -> offset
        | _ -> authority_end (offset + 1)
    in
    let limit = authority_end start in
    let authority = String.sub url start (limit - start) in
    (* Uri's compatibility path parser can absorb malformed authority suffixes.
       Isolate the declared authority and require that it yields no path. *)
    let authority_uri = Uri.of_string (String.sub url 0 limit) in
    let authority_matches =
      Uri.path authority_uri = ""
      && Uri.host authority_uri = Uri.host uri
      && Uri.userinfo authority_uri = Uri.userinfo uri
      && Uri.port authority_uri = Uri.port uri
    in
    let after marker offset = match String.rindex_opt authority marker with
      | None -> true | Some marker_offset -> offset > marker_offset in
    authority_matches &&
    (match String.rindex_opt authority ':' with
    | Some offset when after '@' offset && after ']' offset ->
      let raw = String.sub authority (offset + 1) (String.length authority - offset - 1) in
      if raw = "" then Uri.port uri = None
      else (match int_of_string_opt raw, Uri.port uri with
        | Some requested, Some parsed -> requested = parsed && parsed >= 1 && parsed <= 65535
        | _ -> false)
    | Some _ | None -> Uri.port uri = None)
;;

(* Uri's compatibility grammar accepts arbitrary path octets. Validate the
   RFC3986 character/percent-escape envelope before its structural projection. *)
let endpoint_uri_octets url =
  let open Angstrom in
  let hex = satisfy (function
    | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false) in
  let escaped = char '%' *> count 2 hex *> return () in
  let plain = satisfy (function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9'
    | '-' | '.' | '_' | '~' | ':' | '/' | '?' | '#' | '[' | ']' | '@'
    | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' -> true
    | _ -> false) *> return () in
  parse_string ~consume:All (skip_many (escaped <|> plain)) url
;;

let parse_custom_model selection =
  match String.index_opt selection '@' with
  | None -> Error Missing_endpoint
  | Some at_idx ->
    let model = String.sub selection 0 at_idx |> String.trim in
    let url = String.sub selection (at_idx + 1) (String.length selection - at_idx - 1)
      |> String.trim in
    if model = "" then Error Empty_model
    else if Result.is_error (endpoint_uri_octets url) then Error Invalid_endpoint
    else
      match Angstrom.parse_string ~consume:All Uri.Parser.uri_reference url with
      | Error _ -> Error Invalid_endpoint
      | Ok uri ->
        (match Uri.scheme uri, Uri.host uri with
         | Some ("http" | "https"), Some host
           when host <> "" && endpoint_authority_is_lossless url uri -> Ok (model, url)
         | _ -> Error Invalid_endpoint)
      | exception Invalid_argument _ -> Error Invalid_endpoint
;;
