(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Bs = Authz_browser_session
module Q = Authz_browser_request
module T = Oidc_login_transaction

let ( let* ) = Result.bind

type status =
  | Ok_200
  | No_content_204
  | See_other_303
  | Bad_request_400
  | Unauthorized_401
  | Forbidden_403
  | Not_found_404
  | Conflict_409
  | Too_many_requests_429
  | Internal_error_500
  | Bad_gateway_502
  | Service_unavailable_503
  | Gateway_timeout_504

let status_code = function
  | Ok_200 -> 200
  | No_content_204 -> 204
  | See_other_303 -> 303
  | Bad_request_400 -> 400
  | Unauthorized_401 -> 401
  | Forbidden_403 -> 403
  | Not_found_404 -> 404
  | Conflict_409 -> 409
  | Too_many_requests_429 -> 429
  | Internal_error_500 -> 500
  | Bad_gateway_502 -> 502
  | Service_unavailable_503 -> 503
  | Gateway_timeout_504 -> 504
;;

type answer =
  { status : status
  ; headers : (string * string) list
  ; body : string
  }

type provider =
  | Google
  | Github

type google_login =
  { client : Login_client.t
  ; cache : Oidc_google_exchange.cache
  }

type t =
  { zone : Authz_zone.t
  ; transactions : T.t
  ; google : google_login option
  ; github : Login_client.t option
  ; get : Login_transport.get
  ; post : Login_transport.post
  ; now : unit -> Ptime.t
  ; draw : unit -> string
  }

(* Why an answer is not the one asked for. Only a refusal has one, so a page
   or a JSON error cannot be made with a status that means success. *)
type failure =
  | Bad_request
  | Unauthorized
  | Forbidden
  | Not_found
  | Conflict
  | Internal_error
  | Bad_gateway
  | Unavailable

let failure_status = function
  | Bad_request -> Bad_request_400
  | Unauthorized -> Unauthorized_401
  | Forbidden -> Forbidden_403
  | Not_found -> Not_found_404
  | Conflict -> Conflict_409
  | Internal_error -> Internal_error_500
  | Bad_gateway -> Bad_gateway_502
  | Unavailable -> Service_unavailable_503
;;

(* The sentence of a refused page. None names what was refused, so a page
   tells a visitor nothing about an invitation or an account. *)
let failure_sentence = function
  | Bad_request -> "The sign-in request is not one this server reads."
  | Unauthorized -> "The sign-in did not complete. Start it again."
  | Forbidden -> "This account cannot sign in here."
  | Not_found -> "This sign-in is not set up on this server."
  | Conflict -> "Another sign-in used this invitation or account first."
  | Internal_error -> "The server could not finish the sign-in."
  | Bad_gateway -> "The login provider did not answer as expected. Try again."
  | Unavailable -> "The server cannot sign anyone in right now. Try again later."
;;

(* ---- answers ---- *)

let no_store = "cache-control", "no-store"

(* The callback URL carries the code and the state; the page it answers must
   not send it on as a Referer. *)
let no_referrer = "referrer-policy", "no-referrer"
let html_type = "content-type", "text/html; charset=utf-8"
let json_type = "content-type", "application/json"
let set_cookie value = "set-cookie", value
let page_policy = "default-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

let escape text =
  let buffer = Buffer.create (String.length text) in
  String.iter
    (function
      | '&' -> Buffer.add_string buffer "&amp;"
      | '<' -> Buffer.add_string buffer "&lt;"
      | '>' -> Buffer.add_string buffer "&gt;"
      | '"' -> Buffer.add_string buffer "&quot;"
      | '\'' -> Buffer.add_string buffer "&#39;"
      | other -> Buffer.add_char buffer other)
    text;
  Buffer.contents buffer
;;

let page ~title ~body =
  String.concat
    "\n"
    [ "<!doctype html>"
    ; "<html lang=\"en\">"
    ; "<head>"
    ; "<meta charset=\"utf-8\">"
    ; "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    ; "<title>" ^ title ^ "</title>"
    ; "</head>"
    ; "<body>"
    ; body
    ; "</body>"
    ; "</html>"
    ; ""
    ]
;;

let refused_page failure =
  { status = failure_status failure
  ; headers = [ html_type; no_store; no_referrer; "content-security-policy", page_policy ]
  ; body =
      page
        ~title:"Sign-in failed"
        ~body:(Printf.sprintf "<p>%s</p>\n<p><a href=\"/\">Back</a></p>" (failure_sentence failure))
  }
;;

(* The script reads the path from the link, so no request data is in the
   script, and a browser without scripts follows the link. *)
let completion_page ~nonce ~return_to ~cookie =
  { status = Ok_200
  ; headers =
      [ html_type
      ; no_store
      ; no_referrer
      ; ( "content-security-policy"
        , Printf.sprintf
            "default-src 'none'; script-src 'nonce-%s'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
            nonce )
      ; set_cookie (Q.set_session_cookie cookie)
      ]
  ; body =
      page
        ~title:"Signed in"
        ~body:
          (Printf.sprintf
             "<p>Signed in. <a id=\"next\" href=\"%s\">Continue</a></p>\n\
              <script nonce=\"%s\">location.replace(document.getElementById(\"next\").getAttribute(\"href\"));</script>"
             (escape (T.Local_path.to_string return_to))
             nonce)
  }
;;

let json ?(cookies = []) status fields =
  { status
  ; headers = [ json_type; no_store ] @ List.map set_cookie cookies
  ; body = Yojson.Safe.to_string (`Assoc fields)
  }
;;

let json_refused ?cookies failure text = json ?cookies (failure_status failure) [ "error", `String text ]

(* The reason names a path of the server (issue #50018), so it goes to the
   log and the person gets one fixed sentence. *)
let zone_uncertain_message uncertain =
  Log.Auth.warn
    "a request was refused, because the authorization zone cannot be trusted: %s"
    (Authz_zone.uncertain_to_string uncertain);
  "The server cannot read its accounts right now. Try again later."
;;

let zone_uncertain uncertain = json_refused Unavailable (zone_uncertain_message uncertain)

(* ---- what the routes share ---- *)

(* Milliseconds since the epoch. A float holds them exactly for the next few
   hundred thousand years. *)
let ms_of instant = Float.to_int (Ptime.to_float_s instant *. 1000.)

type configured =
  | Google_login of google_login
  | Github_login of Login_client.t

let configured t = function
  | Google -> Option.map (fun login -> Google_login login) t.google
  | Github -> Option.map (fun client -> Github_login client) t.github
;;

(* ---- start ---- *)

let invite_field = "invite"
let return_to_field = "return_to"

let single fields name =
  match List.filter (fun (key, (_ : string)) -> String.equal key name) fields with
  | [] -> Ok None
  | [ (_, value) ] -> Ok (Some value)
  | _ :: _ :: _ -> Error Bad_request
;;

let read_start_form fields =
  let known (key, (_ : string)) = String.equal key invite_field || String.equal key return_to_field in
  if not (List.for_all known fields)
  then Error Bad_request
  else
    let* invite = single fields invite_field in
    let* return_to = single fields return_to_field in
    let* invite =
      match invite with
      | None -> Ok None
      | Some text ->
        Option.to_result ~none:Bad_request (T.Invite_token.of_form text) |> Result.map Option.some
    in
    let* return_to =
      match return_to with
      | None -> Ok T.Local_path.root
      | Some text -> Option.to_result ~none:Bad_request (T.Local_path.of_string text)
    in
    Ok (invite, return_to)
;;

(* The session of the cookie, when the cookie acts. No cookie acts in a zone
   that cannot be trusted, and the sign-in that follows is refused there. *)
let session_of_browser t ~now_ms = function
  | None -> None
  | Some value ->
    Option.bind (Bs.Cookie.of_value value) (fun cookie ->
      match Authz_zone.read t.zone with
      | Error (_ : Authz_zone.uncertain) -> None
      | Ok trusted ->
        (match Bs.authenticate trusted ~now_ms cookie with
         | Ok { Bs.session_id; user_id = _; expires_at_ms = _ } -> Some session_id
         | Error (_ : Bs.refusal) -> None))
;;

let begin_login t login ~invite ~return_to ~replaces =
  match login with
  | Google_login { client; cache } ->
    (match
       Google_login_flow.start ~get:t.get cache t.transactions client ~now:t.now ~invite ~return_to ~replaces
     with
     | Ok { Google_login_flow.id; authorization_url } -> Ok (id, authorization_url)
     | Error (Google_login_flow.Google_unavailable (_ : Oidc_google_exchange.error)) -> Error Bad_gateway
     | Error Google_login_flow.Transactions_full -> Error Unavailable)
  | Github_login client ->
    (match Github_login_flow.start t.transactions client ~now:t.now ~invite ~return_to ~replaces with
     | Ok { Github_login_flow.id; authorization_url } -> Ok (id, authorization_url)
     | Error T.Full -> Error Unavailable)
;;

let start t provider ~origin ~session_cookie ~fields =
  let started =
    let* login = Option.to_result ~none:Not_found (configured t provider) in
    let* () =
      match origin with
      | Q.Same_origin -> Ok ()
      | Q.Other_origin | Q.No_origin -> Error Forbidden
    in
    let* invite, return_to = read_start_form fields in
    let replaces = session_of_browser t ~now_ms:(ms_of (t.now ())) session_cookie in
    begin_login t login ~invite ~return_to ~replaces
  in
  match started with
  | Error failure -> refused_page failure
  | Ok (id, authorization_url) ->
    { status = See_other_303
    ; headers =
        [ "location", authorization_url; set_cookie (Q.set_transaction_cookie id); no_store; no_referrer ]
    ; body = ""
    }
;;

(* ---- callback ---- *)

type returned =
  | Code of string
  | Refused

let read_callback ~transaction_cookie ~query =
  let* id =
    Option.to_result ~none:Unauthorized (Option.bind transaction_cookie T.Id.of_string)
  in
  let* state = single query "state" in
  let* state = Option.to_result ~none:Bad_request state in
  let* code = single query "code" in
  let* error = single query "error" in
  match code, error with
  | Some code, None -> Ok (id, state, Code code)
  | None, Some (_ : string) -> Ok (id, state, Refused)
  | None, None | Some _, Some _ -> Error Bad_request
;;

let transaction_failure = function
  | T.Unknown | T.Other_flow | T.Expired | T.State_differs -> Unauthorized
;;

let google_failure = function
  | Oidc_google_exchange.Discovery_unavailable (_ : string)
  | Oidc_google_exchange.Discovery_malformed (_ : string)
  | Oidc_google_exchange.Token_unavailable (_ : string)
  | Oidc_google_exchange.Token_answer_malformed
  | Oidc_google_exchange.Keys_unavailable (_ : string) -> Bad_gateway
  | Oidc_google_exchange.Token_refused { status = _; error = _ }
  | Oidc_google_exchange.Signature_refused (_ : Oidc_id_token_signature.error)
  | Oidc_google_exchange.Claims_refused (_ : Oidc_google.error) -> Unauthorized
;;

let github_failure = function
  | Github_oauth.Token_unavailable (_ : string)
  | Github_oauth.User_unavailable (_ : string)
  | Github_oauth.User_answer_malformed
  | Github_oauth.Identity_refused (_ : Authz_external_identity.error) -> Bad_gateway
  | Github_oauth.Token_refused { status = _; error = _ } -> Unauthorized
;;

let login_failure refusal =
  if Authz_login.is_conflict refusal
  then Conflict
  else (
    match refusal with
    | Authz_login.Already_joined (_ : Authz_types.User_id.t) -> Conflict
    | Authz_login.Not_invited
    | Authz_login.Disabled (_ : Authz_types.User_id.t)
    | Authz_login.Blocked (_ : Authz_types.User_id.t)
    | Authz_login.Invitation_unknown
    | Authz_login.Admission_refused (_ : Authz_principal_state.refusal) -> Forbidden
    | Authz_login.Uncertain | Authz_login.Not_bootstrapped | Authz_login.Commit_failed (_ : Authz_zone.error) ->
      Unavailable
    | Authz_login.Id_not_drawn (_ : Authz_id.error) | Authz_login.Body_not_built (_ : Authz_body.error) ->
      Internal_error)
;;

let user_of = function
  | Authz_login.Signed_in user_id -> user_id
  | Authz_login.Admitted { user_id; role = _; previously_deleted = _ } -> user_id
;;

let complete t login id ~state returned =
  match login with
  | Google_login { client; cache } ->
    let answer =
      match returned with
      | Code code -> Google_login_flow.Code code
      | Refused -> Google_login_flow.Refused
    in
    (match
       Google_login_flow.callback
         ~get:t.get
         ~post:t.post
         cache
         t.transactions
         t.zone
         client
         ~now:t.now
         ~draw:t.draw
         id
         ~state
         answer
     with
     | Ok { Google_login_flow.outcome; return_to; replaces } -> Ok (user_of outcome, return_to, replaces)
     | Error (Google_login_flow.Transaction_refused error) -> Error (transaction_failure error)
     | Error Google_login_flow.Refused_at_google -> Error Unauthorized
     | Error (Google_login_flow.Exchange_failed error) -> Error (google_failure error)
     | Error (Google_login_flow.Login_refused refusal) -> Error (login_failure refusal))
  | Github_login client ->
    let answer =
      match returned with
      | Code code -> Github_login_flow.Code code
      | Refused -> Github_login_flow.Refused
    in
    (match
       Github_login_flow.callback
         ~get:t.get
         ~post:t.post
         t.transactions
         t.zone
         client
         ~now:t.now
         ~draw:t.draw
         id
         ~state
         answer
     with
     | Ok { Github_login_flow.outcome; return_to; replaces } -> Ok (user_of outcome, return_to, replaces)
     | Error (Github_login_flow.Transaction_refused error) -> Error (transaction_failure error)
     | Error Github_login_flow.Refused_at_github -> Error Unauthorized
     | Error (Github_login_flow.Exchange_failed error) -> Error (github_failure error)
     | Error (Github_login_flow.Login_refused refusal) -> Error (login_failure refusal))
;;

let issue_failure = function
  | Bs.Id_not_drawn (_ : Authz_id.error) | Bs.Body_not_built (_ : Authz_body.error) -> Internal_error
  | Bs.Commit_failed (_ : Authz_zone.error) -> Unavailable
;;

(* The session that the start named is ended only while it still acts: one
   that was signed out, replaced or expired since the start needs no end, and
   the session record would refuse to end it again. The commit that issues
   the new session judges the record that ends this one, so this reads what
   the zone last published. *)
let still_acting t ~now_ms session_id =
  let sessions = (Authz_zone.snapshot t.zone).Authz_zone.state.Authz_state.sessions in
  match Authz_session_state.find_active sessions session_id ~now_ms with
  | Ok (_ : Authz_session_state.session) -> Some session_id
  | Error (Authz_session_state.Unknown | Authz_session_state.Ended | Authz_session_state.Expired) -> None
;;

let callback t provider ~transaction_cookie ~query =
  let completed =
    let* login = Option.to_result ~none:Not_found (configured t provider) in
    let* id, state, returned = read_callback ~transaction_cookie ~query in
    let* user_id, return_to, replaces = complete t login id ~state returned in
    let now_ms = ms_of (t.now ()) in
    let replaces = Option.bind replaces (still_acting t ~now_ms) in
    let* cookie = Bs.issue t.zone ~user_id ~draw:t.draw ~replaces |> Result.map_error issue_failure in
    Ok (return_to, cookie)
  in
  let answer =
    match completed with
    | Error failure -> refused_page failure
    | Ok (return_to, cookie) -> completion_page ~nonce:(t.draw ()) ~return_to ~cookie
  in
  { answer with headers = answer.headers @ [ set_cookie Q.clear_transaction_cookie ] }
;;

(* ---- sign-out and session ---- *)

let request_failure refusal = if Q.is_unauthenticated refusal then Unauthorized else Forbidden

(* A cookie that does not act is of no use to the browser. A refusal for the
   origin or the token keeps the cookie: a request that another page made
   must not sign the person out. *)
let clears_the_cookie = function
  | Q.Not_a_session_cookie | Q.Session_refused (_ : Bs.refusal) -> true
  | Q.Query_credential
  | Q.Session_and_bearer
  | Q.Cross_origin
  | Q.Origin_missing
  | Q.Csrf_missing
  | Q.Csrf_differs -> false
;;

let no_session = "no session cookie came with the request"

(* A zone that cannot be trusted says nothing of a session, so the cookie of
   the request is kept: the session may still act once the files are read
   again. *)
let logout t request =
  match Authz_zone.read t.zone with
  | Error uncertain -> zone_uncertain uncertain
  | Ok trusted ->
    (match Q.check trusted ~now_ms:(ms_of (t.now ())) request with
     | Error refusal ->
       let cookies = if clears_the_cookie refusal then [ Q.clear_session_cookie ] else [] in
       json_refused ~cookies (request_failure refusal) (Q.refusal_to_string refusal)
     | Ok Q.No_session -> json_refused Unauthorized no_session
     | Ok (Q.Session { cookie = _; signed_in = { Bs.user_id; session_id; expires_at_ms = _ } }) ->
       (match Bs.sign_out t.zone ~user_id session_id with
        | Ok () ->
          { status = No_content_204; headers = [ no_store; set_cookie Q.clear_session_cookie ]; body = "" }
        | Error error -> json_refused (issue_failure error) (Bs.error_to_string error)))
;;

let acting t request =
  match Authz_zone.read t.zone with
  | Error uncertain -> Error (zone_uncertain uncertain)
  | Ok trusted ->
    (match Q.check trusted ~now_ms:(ms_of (t.now ())) request with
     | Error refusal -> Error (json_refused (request_failure refusal) (Q.refusal_to_string refusal))
     | Ok Q.No_session -> Error (json_refused Unauthorized no_session)
     | Ok (Q.Session { cookie; signed_in }) -> Ok (cookie, signed_in))
;;

let session t request =
  match acting t request with
  | Error answer -> answer
  | Ok (cookie, { Bs.user_id; session_id = _; expires_at_ms }) ->
    json
      Ok_200
      [ "user_id", `String (Authz_types.User_id.to_string user_id)
      ; "expires_at_ms", `Int expires_at_ms
      ; "csrf_token", `String (Bs.csrf_token cookie)
      ]
;;

let json status fields = json status fields
