(* HIGH-RISK-UNREVIEWED: see the interface. *)

module Http = Http_server_eio
module Q = Authz_browser_request
module R = Login_routes

(* ---- the transport ---- *)

let response_of { Masc_http_client.status; headers; body } = { Login_transport.status; headers; body }

let get ~clock ~url ~headers =
  Masc_http_client.get_response_sync
    ~clock
    ~timeout_sec:Masc_http_client.default_request_timeout_sec
    ~max_body_bytes:Login_transport.max_answer_bytes
    ~url
    ~headers
    ()
  |> Result.map response_of
;;

let post ~clock ~url ~headers ~body =
  Masc_http_client.post_response_sync
    ~clock
    ~timeout_sec:Masc_http_client.default_request_timeout_sec
    ~max_body_bytes:Login_transport.max_answer_bytes
    ~url
    ~headers
    ~body
    ()
  |> Result.map response_of
;;

(* ---- reading a request ---- *)

let max_request_bytes = 16 * 1024

let method_of (request : Httpun.Request.t) =
  match request.meth with
  | `GET | `HEAD -> Q.Safe
  | `POST | `PUT | `DELETE | `CONNECT | `OPTIONS | `TRACE | `Other (_ : string) -> Q.Unsafe
;;

(* A dev origin that single-user mode allows is another origin here:
   multi-account mode allows no credentialed cross-origin request
   (design 5.3). *)
let origin_of ~request_authority request =
  match Server_auth.classify_request_origin ~request_authority request with
  | Server_auth.Single_origin { admission = Server_auth.Same_origin; origin = (_ : string) } -> Q.Same_origin
  | Server_auth.Single_origin
      { admission = Server_auth.Allowed_dev_origin | Server_auth.Rejected; origin = (_ : string) }
  | Server_auth.Multiple_origins
  | Server_auth.Malformed_origin -> Q.Other_origin
  | Server_auth.Missing_origin -> Q.No_origin
;;

let cookie request name = Server_routes_http_common.get_cookie_value request name

let browser_request ~request_authority request =
  { Q.method_ = method_of request
  ; session_cookie = cookie request Q.session_cookie
  ; bearer = Server_auth.request_carries_auth_credential request
  ; query_credential = Server_auth.request_carries_query_credential request
  ; origin = origin_of ~request_authority request
  ; csrf = Http.Request.header request Q.csrf_header
  }
;;

(* Uri gives [name] with no values both for [name] and for [name=]; that is
   one pair with an empty value, which no route takes for a value. *)
let pairs query =
  List.concat_map
    (fun (name, values) ->
      match values with
      | [] -> [ name, "" ]
      | _ :: _ -> List.map (fun value -> name, value) values)
    query
;;

let query_of (request : Httpun.Request.t) = pairs (Uri.query (Uri.of_string request.target))
let form_of body = pairs (Uri.query_of_encoded body)

(* ---- writing an answer ---- *)

let respond reqd { R.status; headers; body } =
  let headers = headers @ [ "content-length", string_of_int (String.length body) ] in
  Http_reqd.respond_with_string
    reqd
    (Httpun.Response.create
       ~headers:(Httpun.Headers.of_list headers)
       (Httpun.Status.of_code (R.status_code status)))
    body
;;

let with_authority reqd f =
  match Server_request_authority.current () with
  | Some request_authority -> f request_authority
  | None -> Http.Response.internal_error "the request has no admitted authority" reqd
;;

let with_body reqd f =
  Http.Request.read_body_async_with_limit
    reqd
    ~max_bytes:max_request_bytes
    ~on_body:f
    ~on_error:(function
      | Http.Request.Too_large max_bytes ->
        Http.Response.text ~status:`Payload_too_large (Http.Request.too_large_body max_bytes) reqd
      | Http.Request.Internal exn ->
        Log.Misc.warn "login_http: the request body was not read: %s" (Printexc.to_string exn);
        Http.Response.internal_error "the request body was not read" reqd)
;;

let with_browser request reqd f =
  with_authority reqd (fun request_authority -> f (browser_request ~request_authority request))
;;

(* ---- the routes ---- *)

let allowlist_path = "/api/v1/auth/allowlist"
let allowlist_entry_prefix = allowlist_path ^ "/"

let start t provider request reqd =
  with_authority reqd (fun request_authority ->
    with_body reqd (fun body ->
      respond
        reqd
        (R.start
           t
           provider
           ~origin:(origin_of ~request_authority request)
           ~session_cookie:(cookie request Q.session_cookie)
           ~fields:(form_of body))))
;;

(* The transaction cookie and the query are all a callback reads (design 5.2),
   so it needs no authority. *)
let callback t provider request reqd =
  respond
    reqd
    (R.callback t provider ~transaction_cookie:(cookie request Q.transaction_cookie) ~query:(query_of request))
;;

let logout t request reqd =
  with_browser request reqd (fun browser -> with_body reqd (fun (_ : string) -> respond reqd (R.logout t browser)))
;;

let session t request reqd = with_browser request reqd (fun browser -> respond reqd (R.session t browser))

let register t request reqd =
  with_browser request reqd (fun browser ->
    with_body reqd (fun body -> respond reqd (Login_allowlist_routes.register t browser ~body)))
;;

(* The router matched the prefix, so the path holds it; the rest is the id,
   which the route reads. *)
let remove t request reqd =
  let path = Http.Request.path request in
  let prefix = String.length allowlist_entry_prefix in
  if not (String.starts_with ~prefix:allowlist_entry_prefix path)
  then Http.Response.not_found reqd
  else (
    let registration_id = String.sub path prefix (String.length path - prefix) in
    with_browser request reqd (fun browser ->
      with_body reqd (fun (_ : string) ->
        respond reqd (Login_allowlist_routes.remove t browser ~registration_id))))
;;

let access = Server_route.Self_authenticated Route_access.Browser_session
let github_callback_path = "/auth/github/callback"

let add_routes t router =
  router
  |> Server_route.post access "/auth/oidc/start" (start t R.Google)
  |> Server_route.get access "/auth/oidc/callback" (callback t R.Google)
  |> Server_route.post access "/auth/github/start" (start t R.Github)
  |> Server_route.get access github_callback_path (callback t R.Github)
  |> Server_route.post access "/auth/logout" (logout t)
  |> Server_route.get access "/auth/session" (session t)
  |> Server_route.post access allowlist_path (register t)
  |> Server_route.prefix_delete access allowlist_entry_prefix (remove t)
;;

(* ---- the localhost preview (plan, preview scope P3) ---- *)

let whoami_path = "/api/v1/auth/whoami"
let ms_per_second = 1000.

(* Every value of a session cookie, so that two of them are several
   credentials; [cookie] gives only the first. *)
let session_cookie_values (request : Httpun.Request.t) =
  Httpun.Headers.get_multi request.headers "cookie"
  |> List.concat_map (fun raw ->
    Cohttp.Header.init_with "cookie" raw |> Cohttp.Cookie.Cookie_hdr.extract)
  |> List.filter_map (fun (name, value) ->
    match String.equal name Q.session_cookie, String.trim value with
    | false, (_ : string) | true, "" -> None
    | true, value -> Some value)
;;

let gate_request ~request_authority (request : Httpun.Request.t) =
  { Auth_gate.credentials =
      { Authz_credential_presentation.authorization =
          Httpun.Headers.get_multi request.headers Server_auth.authorization_header_name
      ; internal_token = Httpun.Headers.get_multi request.headers Server_auth.internal_token_header_name
      ; session_cookies = session_cookie_values request
      ; query_credential = Server_auth.request_carries_query_credential request
      }
  ; method_ = method_of request
  ; origin = origin_of ~request_authority request
  ; csrf = Http.Request.header request Q.csrf_header
  }
;;

let page answer_of (t : R.t) (_ : Httpun.Request.t) reqd = respond reqd (answer_of ~nonce:(t.draw ()))

let whoami (t : R.t) request reqd =
  with_authority reqd (fun request_authority ->
    respond
      reqd
      (Auth_preview.whoami
         (Authz_zone.snapshot t.zone).Authz_zone.state
         ~now_ms:(int_of_float (Ptime.to_float_s (t.now ()) *. ms_per_second))
         (gate_request ~request_authority request)))
;;

let add_preview_routes t router =
  router
  |> Server_route.get Server_route.Always_public "/" (page Auth_preview.home_page t)
  |> Server_route.get Server_route.Always_public Authz_activation.invitation_path (page Auth_preview.invite_page t)
  |> Server_route.get access whoami_path (whoami t)
;;
