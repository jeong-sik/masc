(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Bs = Authz_browser_session

let session_cookie = "__Host-masc_session"
let transaction_cookie = "__Host-masc_oidc_txn"
let csrf_header = "x-masc-csrf-token"
let milliseconds_per_second = 1000

let set_cookie ~name ~value ~same_site ~max_age_s =
  Printf.sprintf
    "%s=%s; Path=/; Secure; HttpOnly; SameSite=%s; Max-Age=%d"
    name
    value
    same_site
    max_age_s
;;

let set_session_cookie cookie =
  set_cookie
    ~name:session_cookie
    ~value:(Bs.Cookie.to_value cookie)
    ~same_site:"Strict"
    ~max_age_s:(Authz_session_state.lifetime_ms / milliseconds_per_second)
;;

let clear_session_cookie = set_cookie ~name:session_cookie ~value:"" ~same_site:"Strict" ~max_age_s:0

let set_transaction_cookie sealed =
  set_cookie
    ~name:transaction_cookie
    ~value:(Oidc_login_transaction.Sealed.to_string sealed)
    ~same_site:"Lax"
    ~max_age_s:(Oidc_login_transaction.lifetime_ms / milliseconds_per_second)
;;

let clear_transaction_cookie = set_cookie ~name:transaction_cookie ~value:"" ~same_site:"Lax" ~max_age_s:0

type method_ =
  | Safe
  | Unsafe

type origin =
  | Same_origin
  | Other_origin
  | No_origin

type session_cookies =
  | No_cookie
  | One_cookie of string
  | Several_cookies

let session_cookies_of_values = function
  | [] -> No_cookie
  | [ value ] -> One_cookie value
  | _ :: _ :: _ -> Several_cookies
;;

type request =
  { method_ : method_
  ; session_cookie : session_cookies
  ; bearer : bool
  ; query_credential : bool
  ; origin : origin
  ; csrf : string option
  }

type refusal =
  | Query_credential
  | Session_and_bearer
  | Several_session_cookies
  | Not_a_session_cookie
  | Cross_origin
  | Origin_missing
  | Csrf_missing
  | Csrf_differs
  | Session_refused of Bs.refusal

let refusal_to_string = function
  | Query_credential -> "a credential in the query string is not read in multi-account mode"
  | Session_and_bearer -> "the request carries a session cookie and a bearer token; send one"
  | Several_session_cookies -> "the request carries several session cookies; send one"
  | Not_a_session_cookie -> "the session cookie does not hold a session"
  | Cross_origin -> "a request with a session cookie comes from another origin"
  | Origin_missing -> "a request that changes something with a session cookie names no origin"
  | Csrf_missing -> "a request that changes something with a session cookie carries no CSRF token"
  | Csrf_differs -> "the CSRF token is not the one of the session"
  | Session_refused refusal -> Bs.refusal_to_string refusal
;;

let is_unauthenticated = function
  | Query_credential
  | Session_and_bearer
  | Several_session_cookies
  | Not_a_session_cookie
  | Session_refused
      ( Bs.Unknown
      | Bs.Ended
      | Bs.Expired
      | Bs.Secret_differs
      | Bs.Revocation_pending
      | Bs.Principal_inactive (_ : Authz_types.User_id.t)
      | Bs.Principal_revocation_pending (_ : Authz_types.User_id.t) ) -> true
  | Cross_origin | Origin_missing | Csrf_missing | Csrf_differs -> false
;;

type verdict =
  | No_session
  | Session of
      { cookie : Bs.Cookie.t
      ; signed_in : Bs.signed_in
      }

let ( let* ) = Result.bind

(* What a request that changes something needs beside the cookie. *)
let unsafe_needs cookie request =
  match request.method_, request.origin, request.csrf with
  | Safe, (Same_origin | No_origin), (None | Some _) -> Ok ()
  | Unsafe, No_origin, (None | Some _) -> Error Origin_missing
  | Unsafe, Same_origin, None -> Error Csrf_missing
  | Unsafe, Same_origin, Some token ->
    if Bs.csrf_matches cookie token then Ok () else Error Csrf_differs
  | (Safe | Unsafe), Other_origin, (None | Some _) -> Error Cross_origin
;;

let check (trusted : Authz_zone.trusted) ~now_ms request =
  if request.query_credential
  then Error Query_credential
  else (
    match request.session_cookie with
    | No_cookie -> Ok No_session
    | Several_cookies -> Error Several_session_cookies
    | One_cookie (_ : string) when request.bearer -> Error Session_and_bearer
    | One_cookie value ->
      let* cookie = Option.to_result ~none:Not_a_session_cookie (Bs.Cookie.of_value value) in
      let* () = unsafe_needs cookie request in
      let* signed_in =
        Result.map_error (fun refusal -> Session_refused refusal) (Bs.authenticate trusted ~now_ms cookie)
      in
      Ok (Session { cookie; signed_in }))
;;
