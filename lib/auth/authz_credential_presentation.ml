(* HIGH-RISK-UNREVIEWED: see the interface. *)

type request =
  { authorization : string list
  ; internal_token : string list
  ; session_cookies : string list
  ; query_credential : bool
  }

type unreadable =
  | Not_a_bearer
  | Malformed_pat
  | Malformed_service_credential
  | Not_a_session_cookie

type t =
  | No_credential
  | Session of Authz_browser_session.Cookie.t
  | Pat of Authz_credential_token.Pat.t
  | Service_credential of Authz_credential_token.Service_credential.t
  | Mcp_oauth_token
  | Legacy_bearer
  | Query_credential
  | Several
  | Unreadable of unreadable

let unreadable_to_string = function
  | Not_a_bearer -> "the Authorization field is not Bearer and a token"
  | Malformed_pat -> "the bearer starts as a PAT and is not one"
  | Malformed_service_credential -> "the bearer starts as a Service credential and is not one"
  | Not_a_session_cookie -> "the session cookie does not hold a session"
;;

let to_string = function
  | No_credential -> "no credential"
  | Session _ -> "a browser session"
  | Pat _ -> "a scoped PAT"
  | Service_credential _ -> "a Service credential"
  | Mcp_oauth_token -> "an MCP OAuth token"
  | Legacy_bearer -> "a legacy bearer"
  | Query_credential -> "a query credential"
  | Several -> "several credentials"
  | Unreadable unreadable -> unreadable_to_string unreadable
;;

let bearer_scheme = "bearer "
let oauth_access_prefix = "mat_"

(* The token of a field, or [None] when the field is not [Bearer] and a token. *)
let bearer_token field =
  let scheme_length = String.length bearer_scheme in
  if
    String.length field > scheme_length
    && String.equal (String.lowercase_ascii (String.sub field 0 scheme_length)) bearer_scheme
  then (
    match String.trim (String.sub field scheme_length (String.length field - scheme_length)) with
    | "" -> None
    | token -> Some token)
  else None
;;

let of_bearer field =
  match bearer_token field with
  | None -> Unreadable Not_a_bearer
  | Some token ->
    (match Authz_credential_token.read token with
     | Authz_credential_token.Pat_token token -> Pat token
     | Authz_credential_token.Service_credential_token token -> Service_credential token
     | Authz_credential_token.Pat_malformed -> Unreadable Malformed_pat
     | Authz_credential_token.Service_credential_malformed ->
       Unreadable Malformed_service_credential
     | Authz_credential_token.No_prefix ->
       if String.starts_with ~prefix:oauth_access_prefix token
       then Mcp_oauth_token
       else Legacy_bearer)
;;

let of_cookie value =
  match Authz_browser_session.Cookie.of_value value with
  | Some cookie -> Session cookie
  | None -> Unreadable Not_a_session_cookie
;;

(* One credential of the request, before it is read. *)
type piece =
  | Bearer_field of string
  | Internal_field
  | Cookie_value of string
  | In_query

let read { authorization; internal_token; session_cookies; query_credential } =
  let pieces =
    List.map (fun field -> Bearer_field field) authorization
    @ List.map (fun (_ : string) -> Internal_field) internal_token
    @ List.map (fun value -> Cookie_value value) session_cookies
    @ if query_credential then [ In_query ] else []
  in
  match pieces with
  | [] -> No_credential
  | [ Bearer_field field ] -> of_bearer field
  | [ Internal_field ] -> Legacy_bearer
  | [ Cookie_value value ] -> of_cookie value
  | [ In_query ] -> Query_credential
  | _ :: _ :: _ -> Several
;;
