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

(* Every value of a session cookie, over every [Cookie] field, so that two of
   them are several credentials; [cookie] gives only the first. *)
let session_cookie_values (request : Httpun.Request.t) =
  Httpun.Headers.get_multi request.headers "cookie"
  |> List.concat_map (fun raw ->
    Cohttp.Header.init_with "cookie" raw |> Cohttp.Cookie.Cookie_hdr.extract)
  |> List.filter_map (fun (name, value) ->
    match String.equal name Q.session_cookie, String.trim value with
    | false, (_ : string) | true, "" -> None
    | true, value -> Some value)
;;

let session_cookies request = Q.session_cookies_of_values (session_cookie_values request)

let browser_request ~request_authority request =
  { Q.method_ = method_of request
  ; session_cookie = session_cookies request
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
(* A form is sequences split by '&', and an empty sequence holds no field
   (URL standard, the application/x-www-form-urlencoded parser). Uri reads
   the empty body, a trailing '&' and "&&" as a field with an empty name, which
   the start route refuses as unknown, so the empty sequences go first. *)
let form_of body =
  String.split_on_char '&' body
  |> List.filter (fun sequence -> not (String.equal sequence ""))
  |> List.concat_map (fun sequence -> pairs (Uri.query_of_encoded sequence))
;;

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

let with_body ?(max_bytes = max_request_bytes) reqd f =
  Http.Request.read_body_async_with_limit
    reqd
    ~max_bytes
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

let allowlist_path = Login_allowlist_routes.path
let allowlist_entry_prefix = allowlist_path ^ "/"
let invites_path = Login_invite_routes.path
let invite_entry_prefix = invites_path ^ "/"
let pats_path = Login_pat_routes.path
let pat_prefix = pats_path ^ "/"

let start t provider request reqd =
  with_authority reqd (fun request_authority ->
    with_body reqd (fun body ->
      respond
        reqd
        (R.start
           t
           provider
           ~origin:(origin_of ~request_authority request)
           ~session_cookie:(session_cookies request)
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
let with_entry ~prefix request reqd f =
  let path = Http.Request.path request in
  if not (String.starts_with ~prefix path)
  then Http.Response.not_found reqd
  else f (String.sub path (String.length prefix) (String.length path - String.length prefix))
;;

let remove t request reqd =
  with_entry ~prefix:allowlist_entry_prefix request reqd (fun registration_id ->
    with_browser request reqd (fun browser ->
      with_body reqd (fun (_ : string) ->
        respond reqd (Login_allowlist_routes.remove t browser ~registration_id))))
;;

let issue_invite t request reqd =
  with_browser request reqd (fun browser ->
    with_body reqd (fun body -> respond reqd (Login_invite_routes.issue t browser ~body)))
;;

let revoke_invite t request reqd =
  with_entry ~prefix:invite_entry_prefix request reqd (fun invite_id ->
    with_browser request reqd (fun browser ->
      with_body reqd (fun (_ : string) ->
        respond reqd (Login_invite_routes.revoke t browser ~invite_id))))
;;

let issue_pat t request reqd =
  with_browser request reqd (fun browser ->
    with_body reqd (fun body -> respond reqd (Login_pat_routes.issue t browser ~body)))
;;

let list_pats t request reqd =
  with_browser request reqd (fun browser -> respond reqd (Login_pat_routes.list t browser))
;;

let revoke_pat t request reqd =
  with_entry ~prefix:pat_prefix request reqd (fun pat_id ->
    with_browser request reqd (fun browser ->
      with_body reqd (fun (_ : string) -> respond reqd (Login_pat_routes.revoke t browser ~pat_id))))
;;

let access = Server_route.Self_authenticated Route_access.Browser_session
let google_callback_path = "/auth/oidc/callback"
let github_callback_path = "/auth/github/callback"

let add_routes t router =
  router
  |> Server_route.post access "/auth/oidc/start" (start t R.Google)
  |> Server_route.get access google_callback_path (callback t R.Google)
  |> Server_route.post access "/auth/github/start" (start t R.Github)
  |> Server_route.get access github_callback_path (callback t R.Github)
  |> Server_route.post access "/auth/logout" (logout t)
  |> Server_route.get access "/auth/session" (session t)
  |> Server_route.post access allowlist_path (register t)
  |> Server_route.prefix_delete access allowlist_entry_prefix (remove t)
  |> Server_route.post access invites_path (issue_invite t)
  |> Server_route.prefix_delete access invite_entry_prefix (revoke_invite t)
  |> Server_route.post access pats_path (issue_pat t)
  |> Server_route.get access pats_path (list_pats t)
  |> Server_route.prefix_delete access pat_prefix (revoke_pat t)
;;

(* ---- the pages and the routes of a person (plan, preview scope P3, S1a-3b) ---- *)

let whoami_path = "/api/v1/auth/whoami"
let ms_per_second = 1000.
let now_ms (t : R.t) = int_of_float (Ptime.to_float_s (t.now ()) *. ms_per_second)

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

let page answer_of (t : R.t) (_ : Httpun.Request.t) reqd =
  respond reqd (answer_of ~nonce:(t.draw ()) ~github:(Option.is_some t.github))
;;

(* A request is judged on one snapshot of the zone, and only on one the zone
   could be trusted for. A zone whose file stopped, or whose files disagree,
   gives none, and the request gets a 503 before any credential is read. *)
let on_trusted (t : R.t) reqd f =
  match Authz_zone.read t.zone with
  | Error uncertain -> respond reqd (R.zone_uncertain uncertain)
  | Ok trusted -> f trusted
;;

let whoami (t : R.t) request reqd =
  with_authority reqd (fun request_authority ->
    on_trusted t reqd (fun trusted ->
      respond
        reqd
        (Auth_preview.whoami trusted ~now_ms:(now_ms t) (gate_request ~request_authority request))))
;;

(* The one a route of a person acts for, judged by [gate]. [f] gets the state
   of the snapshot that judged the request. *)
let as_gated (t : R.t) ~gate request reqd f =
  with_authority reqd (fun request_authority ->
    on_trusted t reqd (fun trusted ->
      match gate trusted ~now_ms:(now_ms t) (gate_request ~request_authority request) with
      | Error answer -> respond reqd answer
      | Ok who -> f (trusted :> Authz_zone.snapshot).Authz_zone.state who))
;;

(* The person a subscription route acts for; the connect handler checks the
   session of a login against them again on every status and control
   request. *)
let as_person t request reqd f = as_gated t ~gate:Auth_preview.person request reqd f

let person_of (t : R.t) { Auth_preview.user_id; namespace } =
  { Server_setup_account_login.zone = t.zone; user_id; namespace }
;;

let owner_of t person = Server_setup_account_login.Person (person_of t person)

let connect t ~base_path request reqd =
  as_person t request reqd (fun (_ : Authz_state.t) person ->
    with_body reqd (fun body ->
      Server_setup_account_login.start ~owner:(owner_of t person) ~base_path ~body request reqd))
;;

let login_status t ~base_path request reqd =
  as_person t request reqd (fun (_ : Authz_state.t) person ->
    Server_setup_account_login.status ~owner:(owner_of t person) ~base_path request reqd)
;;

let login_control t ~base_path request reqd =
  as_person t request reqd (fun (_ : Authz_state.t) person ->
    with_body reqd (fun body ->
      Server_setup_account_login.control ~owner:(owner_of t person) ~base_path ~body request reqd))
;;

let verify t ~base_path request reqd =
  as_person t request reqd (fun (_ : Authz_state.t) person ->
    with_body reqd (fun body ->
      Server_setup_account_login.verify ~person:(person_of t person) ~base_path ~body request reqd))
;;

let provider_accounts t request reqd =
  as_person t request reqd (fun state person -> respond reqd (Auth_preview.provider_accounts state person))
;;

let integrations t ~base_path request reqd =
  as_person t request reqd (fun (_ : Authz_state.t) (_ : Auth_preview.person) ->
    respond reqd (Server_person_integrations.answer ~base_path))
;;

let as_keeper_owner t request reqd f = as_gated t ~gate:Auth_preview.keeper_owner request reqd f

let keepers t request reqd =
  as_keeper_owner t request reqd (fun state user_id ->
    respond reqd (Auth_preview_keeper.list state user_id))
;;

let make_keeper (t : R.t) request reqd =
  as_keeper_owner t request reqd (fun (_ : Authz_state.t) user_id ->
    with_body reqd (fun body -> respond reqd (Auth_preview_keeper.make t.zone user_id ~body)))
;;

let assign_keeper (t : R.t) request reqd =
  as_keeper_owner t request reqd (fun (_ : Authz_state.t) user_id ->
    with_body reqd (fun body -> respond reqd (Auth_preview_keeper.assign t.zone user_id ~body)))
;;

(* A conversation is recorded under the namespace of the person, so the gate
   that gives it judges the request. The token is not read: starting a
   conversation calls no model. *)
let new_keeper_conversation t ~env ~base_path request reqd =
  as_gated
    t
    ~gate:Auth_preview.keeper_turn_caller
    request
    reqd
    (fun (_ : Authz_state.t) { Auth_preview.person; pat = (_ : Authz_types.Pat_binding.t) } ->
       with_body reqd (fun body ->
         respond
           reqd
           (Server_preview_keeper_conversation.start
              ~env
              ~person:(person_of t person)
              ~base_path
              ~body)))
;;

(* What a person asked and was answered is read by one judged both as the
   owner of the Keeper and as a reader of state: a token that lists Keepers
   and has no [read_state] does not read their conversations (plan S1b-3). *)
let keeper_conversation t ~base_path request reqd =
  as_gated
    t
    ~gate:Auth_preview.keeper_conversation_reader
    request
    reqd
    (fun (_ : Authz_state.t) person ->
       respond
         reqd
         (Server_preview_keeper_conversation.read
            ~person:(person_of t person)
            ~base_path
            ~query:(query_of request)))
;;

(* A turn starts the client of the person's account on a home under their
   namespace, inside the scope of the token that authenticated the request,
   so its gate gives both. *)
let keeper_turn t ~env ~base_path request reqd =
  as_gated
    t
    ~gate:Auth_preview.keeper_turn_caller
    request
    reqd
    (fun (_ : Authz_state.t) { Auth_preview.person; pat } ->
       with_body reqd (fun body ->
         respond
           reqd
           (Server_preview_keeper_turn.run ~env ~person:(person_of t person) ~pat ~base_path ~body)))
;;

(* ---- the MCP endpoint of a person (plan S1b-1) ---- *)

let mcp_access = Server_route.Self_authenticated Route_access.Person_mcp

let respond_mcp reqd { Server_person_mcp.status; headers; body } =
  let headers = headers @ [ "content-length", string_of_int (String.length body) ] in
  Http_reqd.respond_with_string reqd (Httpun.Response.create ~headers:(Httpun.Headers.of_list headers) status) body
;;

(* The credential is judged before the body is read, and the tools judge the
   same request on the same snapshot. *)
let person_mcp (t : R.t) ~env ~base_path request reqd =
  with_authority reqd (fun request_authority ->
    on_trusted t reqd (fun trusted ->
      let installation = { Server_person_mcp.zone = t.zone; env; base_path } in
      let caller =
        { Server_person_mcp.trusted; now_ms = now_ms t; gate = gate_request ~request_authority request }
      in
      match Server_person_mcp.admitted caller with
      | Error answer -> respond reqd answer
      | Ok () ->
        with_body ~max_bytes:Server_person_mcp.max_message_bytes reqd (fun body ->
          respond_mcp reqd (Server_person_mcp.answer installation caller request ~body))))
;;

let add_person_routes t ~env ~base_path router =
  router
  |> Server_route.get Server_route.Always_public "/" (page Auth_preview.home_page t)
  |> Server_route.get Server_route.Always_public Authz_activation.invitation_path (page Auth_preview.invite_page t)
  |> Server_route.get access whoami_path (whoami t)
  |> Server_route.get access Auth_preview.provider_accounts_path (provider_accounts t)
  |> Server_route.get access Server_person_integrations.path (integrations t ~base_path)
  |> Server_route.post access Auth_preview.connect_path (connect t ~base_path)
  |> Server_route.post access Auth_preview.verify_path (verify t ~base_path)
  |> Server_route.get access Auth_preview_keeper.keepers_path (keepers t)
  |> Server_route.post access Auth_preview_keeper.keepers_path (make_keeper t)
  |> Server_route.post access Auth_preview_keeper.assign_path (assign_keeper t)
  |> Server_route.post access Auth_preview_keeper.turn_path (keeper_turn t ~env ~base_path)
  |> Server_route.post
       access
       Auth_preview_keeper.conversation_path
       (new_keeper_conversation t ~env ~base_path)
  |> Server_route.get access Auth_preview_keeper.conversation_path (keeper_conversation t ~base_path)
  |> Server_route.prefix_get access Auth_preview.connect_prefix (login_status t ~base_path)
  |> Server_route.prefix_post access Auth_preview.connect_prefix (login_control t ~base_path)
  |> Server_route.post mcp_access Server_person_mcp.path (person_mcp t ~env ~base_path)
;;
