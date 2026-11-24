(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module R = Login_routes

let github_authorize_origin = "https://github.com"
let google_authorize_origin = "https://accounts.google.com"

(* The start of a login answers a 303 to GitHub (or Google when configured),
   and a browser checks [form-action] on that redirect too. *)
let policy ?(google = false) ~nonce () =
  let form_origins =
    if google
    then github_authorize_origin ^ " " ^ google_authorize_origin
    else github_authorize_origin
  in
  Printf.sprintf
    "default-src 'none'; script-src %s; %s; connect-src 'self'; form-action 'self' %s; \
     base-uri 'none'; frame-ancestors 'none'"
    (Csp_nonce.source nonce)
    (Account_page.style_source ~nonce)
    form_origins
;;

(* Under no-referrer a browser sends "Origin: null" with a form POST (Fetch,
   "append a request Origin header"), and the start route refuses a null
   origin; Chromium 148 did so on 2026-11-08. same-origin keeps the origin on
   the form and still sends no Referer to GitHub. *)
let referrer_policy = "referrer-policy", "same-origin"

let page ?(google = false) ~nonce ~title ~body ~script () =
  { R.status = R.Ok_200
  ; headers =
      [ "content-type", "text/html; charset=utf-8"
      ; "cache-control", "no-store"
      ; referrer_policy
      ; "content-security-policy", policy ~google ~nonce ()
      ]
  ; body =
      Account_page.document
        ~nonce
        ~title
        (String.concat
           "\n"
           [ "<main>"
           ; body
           ; "</main>"
           ; Printf.sprintf "<script %s>%s</script>" (Csp_nonce.attribute nonce) script
           ])
  }
;;

(* The form is the same whether the server has a GitHub login client or
   not, so the scripts of the pages find its elements either way. Without a
   client the start is a 404, and the button cannot be pressed. *)
let no_github_login =
  "이 서버에는 GitHub 로그인이 설정되어 있지 않아요. 이 서버를 운영하는 사람에게 알려 주세요."
;;

let escape_html text =
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

let dashboard_account_path = "/dashboard#account"

(* Strictly validate relative return_to paths via [Oidc_login_transaction.Local_path]
   (starts with "/", never "//", no scheme or backslash). The dashboard account
   anchor ["/dashboard#account"] maps to [Account_page.console_path], which passes
   [Local_path] validation on [/auth/*/start] and 303-redirects to ["/dashboard#account"]. *)
let resolve_return_to = function
  | None -> Account_page.console_path
  | Some raw ->
    if String.equal raw dashboard_account_path
    then Account_page.console_path
    else (
      match Oidc_login_transaction.Local_path.of_string raw with
      | Some path -> Oidc_login_transaction.Local_path.to_string path
      | None -> Account_page.console_path)
;;

let transport_callout = function
  | Authz_browser_request.Https_secure_cookies -> []
  | Authz_browser_request.Loopback_http_cookies as status ->
    (match Authz_browser_request.cookie_transport_warning status with
     | None -> []
     | Some warning ->
       [ Printf.sprintf
           "<p id=\"transport-note\" class=\"callout\" role=\"note\" data-cookie-transport=\"%s\">%s</p>"
           (Authz_browser_request.cookie_transport_code status)
           (escape_html warning)
       ])
  | Authz_browser_request.Non_https_cookies_dropped as status ->
    (match Authz_browser_request.cookie_transport_warning status with
     | None -> []
     | Some warning ->
       [ Printf.sprintf
           "<p id=\"transport-note\" class=\"callout\" role=\"alert\" data-cookie-transport=\"%s\">%s</p>"
           (Authz_browser_request.cookie_transport_code status)
           (escape_html warning)
       ])
;;

(* [label] is what the button says: each page names what the login does
   there. *)
let start_form ~invite ~github ~return_to ~label =
  String.concat
    "\n"
    [ "<form method=\"post\" action=\"/auth/github/start\">"
    ; (if invite then "<input type=\"hidden\" id=\"invite\" name=\"invite\">" else "")
    ; Printf.sprintf
        "<input type=\"hidden\" id=\"return-to\" name=\"return_to\" value=\"%s\">"
        (escape_html return_to)
    ; Printf.sprintf
        "<button id=\"go\" class=\"primary block\"%s>%s</button>"
        (if github then "" else " disabled aria-describedby=\"go-note\"")
        label
    ; "</form>"
    ; (if github then "" else "<p id=\"go-note\" class=\"callout\">" ^ no_github_login ^ "</p>")
    ]
;;

let google_start_form ~invite ~google ~return_to ~label =
  if not google
  then ""
  else
    String.concat
      "\n"
      [ "<form method=\"post\" action=\"/auth/oidc/start\">"
      ; (if invite then "<input type=\"hidden\" id=\"google-invite\" name=\"invite\">" else "")
      ; Printf.sprintf
          "<input type=\"hidden\" name=\"return_to\" value=\"%s\">"
          (escape_html return_to)
      ; Printf.sprintf "<button id=\"google-go\" class=\"button block\">%s</button>" label
      ; "</form>"
      ]
;;

(* The script takes the token from the fragment and drops the fragment from
   the address bar, so the token is in no request line, and the entry of the
   tab's history that the page read it in keeps the address without it. The
   list of visited pages of the browser keeps the address as it was opened,
   and a page cannot take it out of there. An address with no token cannot
   start a login that takes an invitation, so the page shows how to open the
   invitation again in place of the form.

   A link that is opened in a tab that already shows this page changes only
   the fragment, and a browser does not load the document again for that. The
   page then turns its button off, hides its form, says that it loads the new
   link, and loads itself again. So the form of the link before cannot be sent
   while the server answers, by a pointer or by a key on a button that kept
   the focus. When the answer is this page, it reads the new link; any other
   answer, such as a 503, leaves the link in the address bar. A load that is
   stopped before the answer leaves the page saying that it loads, with a word
   on how to load it again. *)
let invite_script =
  {|const token = location.hash.slice(1);
history.replaceState(null, "", location.pathname);
addEventListener("hashchange", () => {
  document.getElementById("go").disabled = true;
  const googleGo = document.getElementById("google-go");
  if (googleGo) googleGo.disabled = true;
  document.getElementById("accept").hidden = true;
  document.getElementById("note").textContent =
    "새 초대 링크를 불러오고 있어요. 화면이 바뀌지 않으면 새로고침해 주세요.";
  location.reload();
});
document.getElementById("invite").value = token;
const googleInvite = document.getElementById("google-invite");
if (googleInvite) googleInvite.value = token;
if (token === "") {
  document.title = "이 주소에는 초대 정보가 없어요";
  document.getElementById("title").textContent = document.title;
  document.getElementById("note").textContent =
    "받은 초대 링크 전체를 그대로 다시 열어 주세요. 주소 끝의 # 뒤 글자까지 있어야 해요.";
  document.getElementById("accept").hidden = true;
  document.getElementById("back").hidden = false;
}|}
;;

let invite_page ?return_to ?(cookie_transport = Authz_browser_request.Https_secure_cookies)
    ~google ~nonce ~github () =
  let return_to = resolve_return_to return_to in
  page
    ~google
    ~nonce
    ~title:"MASC 초대"
    ~body:
      (String.concat
         "\n"
         ([ "<div class=\"narrow\">"
          ; "<div class=\"card\">"
          ; "<h1 id=\"title\">초대를 받았어요</h1>"
          ; "<p id=\"note\">계정으로 로그인하면 초대를 수락하고 이 서버를 쓸 수 있어요.</p>"
          ; "<div id=\"accept\">"
          ; start_form ~invite:true ~github ~return_to ~label:"GitHub로 로그인하고 수락하기"
          ]
          @ (if google
             then
               [ google_start_form
                   ~invite:true
                   ~google
                   ~return_to
                   ~label:"Google로 로그인하고 수락하기"
               ]
             else [])
          @ transport_callout cookie_transport
          @ [ "<ul class=\"notes\">"
            ; "<li>초대 링크는 한 번만 쓸 수 있어요.</li>"
            ; "<li>기한이 지나면 쓸 수 없어요.</li>"
            ; "</ul>"
            ; "</div>"
            ; "<p id=\"back\" hidden><a class=\"button block\" href=\"/\">로그인 화면으로</a></p>"
            ; "</div>"
            ; "</div>"
            ]))
    ~script:invite_script
    ()
;;

(* The subscription connect route of the server, which the preview serves
   for a person (plan D1-4), and the list of what a person owns. *)
let connect_path = "/api/v1/setup/accounts/login"
let connect_prefix = connect_path ^ "/"
let provider_accounts_path = "/api/v1/auth/provider-accounts"
let verify_path = "/api/v1/setup/accounts/verify"

(* The session routes answer one of three things: a session (200), no
   session (401), and anything else, which leaves that unknown. The page shows
   the sign-in until it knows where the person goes, so a browser that runs no
   script can still sign in; a signed-in person sees it meanwhile, while the
   page reads the session and asks for the console. Once the answers come, the
   sign-in is shown for a 401 alone: shown for a server that cannot tell, it
   would say to a signed-in person that the session is over.

   A session goes on to the console of the person, the address the form
   returns to, and the page takes itself out of the history of the tab, so
   Back does not come here again. It asks for the console first. A server
   that cannot give the console answers it with a page that links back here
   (a 503 when the dashboard bundle cannot be read), and the two would send
   the person to each other. The page then stays and says so, and offers the
   sign-out that only the console has.

   The server refuses a sign-out whose token is not the one of the session,
   which is what the page holds when another tab signed in. After a refusal
   the page reads the session again, as the console does: a session that
   ended leaves the person out, a session of another person loads the page
   again for that person, and a token of the same person that changed is sent
   once more. *)
let home_script =
  Printf.sprintf
    {|const views = ["signin", "unread", "stuck"].map((id) => document.getElementById(id));
const consolePath = document.getElementById("return-to").value;
const leave = document.getElementById("leave");
const leaveNote = document.getElementById("leave-note");
let csrf = "";
let user = "";
let leaving = false;
function only(id) {
  for (const view of views) view.hidden = view.id !== id;
}
async function readSession() {
  try {
    const answer = await fetch("/auth/session");
    if (answer.status !== 200) return { status: answer.status };
    const session = await answer.json();
    return typeof session.csrf_token === "string" && typeof session.user_id === "string"
      ? { status: 200, csrf: session.csrf_token, user: session.user_id }
      : { status: 0 };
  } catch {
    return { status: 0 };
  }
}
const signOut = (token) =>
  fetch("/auth/logout", { method: "POST", headers: { "%s": token } }).then((answer) => answer.status, () => 0);
const out = (status) => status === 204 || status === 401;
async function show() {
  const session = await readSession();
  if (session.status !== 200) {
    only(session.status === 401 ? "signin" : "unread");
    return;
  }
  const opened = await fetch(consolePath).then((answer) => answer.status, () => 0);
  if (opened === 200) {
    location.replace(consolePath);
    return;
  }
  csrf = session.csrf;
  user = session.user;
  only("stuck");
}
leave.addEventListener("click", async () => {
  if (leaving) return;
  leaving = true;
  leave.setAttribute("aria-disabled", "true");
  leaveNote.textContent = "";
  let status = await signOut(csrf);
  if (!out(status)) {
    const now = await readSession();
    if (now.status === 401 || (now.status === 200 && now.user !== user)) {
      location.reload();
      return;
    }
    if (now.status === 200 && now.csrf !== csrf) {
      csrf = now.csrf;
      status = await signOut(csrf);
    }
  }
  if (out(status)) {
    location.reload();
    return;
  }
  leaving = false;
  leave.removeAttribute("aria-disabled");
  leaveNote.textContent = "로그아웃하지 못했어요. 잠시 뒤에 다시 눌러 주세요.";
});
show();|}
    Authz_browser_request.csrf_header
;;

let home_page ?return_to ?(cookie_transport = Authz_browser_request.Https_secure_cookies)
    ~google ~nonce ~github () =
  let return_to = resolve_return_to return_to in
  page
    ~google
    ~nonce
    ~title:"MASC 계정"
    ~body:
      (String.concat
         "\n"
         ([ "<div id=\"signin\" class=\"narrow\">"
          ; "<div class=\"card\">"
          ; "<h1>로그인</h1>"
          ; "<p>초대받은 계정으로 로그인하면 내 구독을 연결하고 내 Keeper를 만들 수 있어요.</p>"
          ; start_form ~invite:false ~github ~return_to ~label:"GitHub로 계속하기"
          ]
          @ (if google
             then
               [ google_start_form ~invite:false ~google ~return_to ~label:"Google로 계속하기" ]
             else [])
          @ transport_callout cookie_transport
          @ [ "</div>"
            ; "<p class=\"hint center\">초대 링크를 받았다면 그 링크를 먼저 열어 주세요. 초대는 이 서버를 운영하는 사람에게 요청할 수 있어요.</p>"
            ; "</div>"
              (* The two views below are shown in place of the sign-in, so each
                 is an alert: a screen reader says it as it appears. This one is
                 for session routes that did not say whether a session is
                 open. *)
            ; "<div id=\"unread\" class=\"narrow\" role=\"alert\" hidden>"
            ; "<div class=\"card\">"
            ; "<h1>로그인 상태를 확인하지 못했어요</h1>"
            ; "<p>서버가 지금 로그인 상태를 알려 주지 못해요. 로그인은 그대로일 수 있어요. 잠시 뒤에 다시 열어 주세요.</p>"
            ; "<p><a class=\"button block\" href=\"/\">다시 열기</a></p>"
            ; "</div>"
            ; "<p class=\"hint center\">계속 이러면 이 서버를 운영하는 사람에게 알려 주세요.</p>"
            ; "</div>"
              (* For a session whose console the server cannot give now. *)
            ; "<div id=\"stuck\" class=\"narrow\" role=\"alert\" hidden>"
            ; "<div class=\"card\">"
            ; "<h1>지금은 내 계정 화면을 열 수 없어요</h1>"
            ; "<p>로그인은 되어 있어요. 서버가 지금 이 화면을 보여 주지 못해요. 잠시 뒤에 다시 열어 주세요.</p>"
            ; "<p><a class=\"button primary block\" href=\"/\">다시 열기</a></p>"
            ; "<p><button id=\"leave\" type=\"button\" class=\"block\">로그아웃</button></p>"
            ; "<p id=\"leave-note\" class=\"hint\" role=\"status\"></p>"
            ; "</div>"
            ; "<p class=\"hint center\">계속 이러면 이 서버를 운영하는 사람에게 알려 주세요.</p>"
            ; "</div>"
            ]))
    ~script:home_script
    ()
;;

let principal_json = function
  | Principal.Human user_id ->
    `Assoc [ "kind", `String "human"; "id", `String (User_id.to_string user_id) ]
  | Principal.Service service_id ->
    `Assoc [ "kind", `String "service"; "id", `String (Service_id.to_string service_id) ]
;;

let binding_json = function
  | Auth_gate.Session id -> `Assoc [ "kind", `String "session"; "id", `String (Session_id.to_string id) ]
  | Auth_gate.Pat id -> `Assoc [ "kind", `String "pat"; "id", `String (Pat_id.to_string id) ]
  | Auth_gate.Service_credential id ->
    `Assoc [ "kind", `String "service_credential"; "id", `String (Service_credential_id.to_string id) ]
;;

let refused reason =
  R.json
    (if Auth_gate.is_unauthenticated reason then R.Unauthorized_401 else R.Forbidden_403)
    [ "error", `String (Auth_gate.reason_to_string reason) ]
;;

let whoami trusted ~now_ms request =
  match Auth_gate.decide trusted ~now_ms Route_access.Read_auth request with
  | Ok (Auth_gate.Authenticated { Auth_gate.principal; binding; role; pat_binding = _ }) ->
    R.json
      R.Ok_200
      [ "principal", principal_json principal
      ; "role", `String (Masc_domain.agent_role_to_string role)
      ; "binding", binding_json binding
      ]
  | Ok (Auth_gate.Anonymous | Auth_gate.Judged_by_route) ->
    (* [Read_auth] needs a credential, so [decide] answers neither of these
       for it; were it to, no one is signed in. *)
    refused Auth_gate.Credential_required
  | Error reason -> refused reason
;;

type person =
  { user_id : User_id.t
  ; namespace : Account_home_namespace.t
  }

(* The human a [Manage_own_*] route lets through, with the personal access
   token that authenticated the request, if one did. *)
let authenticated_human trusted ~now_ms access ~service_refused request =
  match Auth_gate.decide trusted ~now_ms access request with
  | Error reason -> Error (refused reason)
  | Ok
      (Auth_gate.Authenticated
         { Auth_gate.principal = Principal.Human user_id; pat_binding; binding = _; role = _ }) ->
    Ok (user_id, pat_binding)
  | Ok (Auth_gate.Authenticated { Auth_gate.principal = Principal.Service service_id; _ }) ->
    (* [decide] refuses a service on these kinds; were it not to, it still
       owns nothing. *)
    Error (refused (service_refused service_id))
  | Ok (Auth_gate.Anonymous | Auth_gate.Judged_by_route) ->
    (* These kinds need a credential, so [decide] answers neither. *)
    Error (refused Auth_gate.Credential_required)
;;

(* The human a [Manage_own_*] route lets through. *)
let human trusted ~now_ms access ~service_refused request =
  Result.map
    (fun (user_id, (_ : Pat_binding.t)) -> user_id)
    (authenticated_human trusted ~now_ms access ~service_refused request)
;;

(* The person of [user_id], with the namespace their admission fixed. *)
let with_namespace (trusted : Authz_zone.trusted) user_id =
  let state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
  match Authz_principal_state.find_membership state.Authz_state.principals user_id with
  | Some { Authz_principal_state.account_home_namespace = namespace; workspace_id = _ } ->
    Ok { user_id; namespace }
  | None ->
    (* The admission that made an active principal made its membership in
       the same record, so none is a log this build did not write. *)
    Error (R.json R.Internal_error_500 [ "error", `String "the principal has no membership" ])
;;

(* The human a [Manage_own_*] route lets through, with the namespace their
   admission fixed. *)
let member trusted ~now_ms access ~service_refused request =
  Result.bind (human trusted ~now_ms access ~service_refused request) (with_namespace trusted)
;;

let person trusted ~now_ms request =
  member
    trusted
    ~now_ms
    Route_access.Manage_own_provider
    ~service_refused:(fun service_id -> Auth_gate.Service_owns_no_provider service_id)
    request
;;

let keeper_owner trusted ~now_ms request =
  human
    trusted
    ~now_ms
    Route_access.Manage_own_keeper
    ~service_refused:(fun service_id -> Auth_gate.Service_owns_no_keeper service_id)
    request
;;

type turn_caller =
  { person : person
  ; pat : Pat_binding.t
  }

let keeper_turn_caller trusted ~now_ms request =
  Result.bind
    (authenticated_human
       trusted
       ~now_ms
       Route_access.Manage_own_keeper
       ~service_refused:(fun service_id -> Auth_gate.Service_owns_no_keeper service_id)
       request)
    (fun (user_id, pat) ->
      Result.map (fun person -> { person; pat }) (with_namespace trusted user_id))
;;

let keeper_conversation_reader trusted ~now_ms request =
  Result.bind
    (keeper_turn_caller trusted ~now_ms request)
    (fun { person; pat = (_ : Pat_binding.t) } ->
      match Auth_gate.decide trusted ~now_ms Route_access.Read_auth request with
      | Ok (Auth_gate.Authenticated (_ : Auth_gate.authenticated)) -> Ok person
      | Ok (Auth_gate.Anonymous | Auth_gate.Judged_by_route) ->
        (* [Read_auth] needs a credential, so [decide] answers neither. *)
        Error (refused Auth_gate.Credential_required)
      | Error reason -> Error (refused reason))
;;

(* Why the model of a Runtime is not known. *)
type model_unread =
  | Configuration_unavailable
  | Not_bound of Runtime_account_runtime.error

let model_unread_code = function
  | Configuration_unavailable -> "configuration_unavailable"
  | Not_bound error -> Runtime_account_runtime.error_code error
;;

(* The model of the binding of the account's template that makes the
   Runtime id, the binding a turn of the Runtime finds: the key of its
   [models.<id>] table, as the integrations list names it and a
   verification takes it. A turn sends that model's [api-name], which may
   be another name. A Runtime id names its binding, so only
   [template_not_declared] and [runtime_not_bound] come back. *)
let model_of ~config ~integration id (runtime : Authz_runtime_state.runtime) =
  match config with
  | None -> Error Configuration_unavailable
  | Some config ->
    Runtime_account_runtime.binding_of
      config
      ~template:integration
      ~provider_id:(Provider_account_id.to_string runtime.provider_account_id)
      ~binding:(Runtime_account_runtime.Runtime (Runtime_id.to_string id))
    |> Result.map (fun (binding : Runtime_schema.binding) -> binding.model_id)
    |> Result.map_error (fun error -> Not_bound error)
;;

(* A fact as [name], or [null] and the code of why it was not read. *)
let fact name code = function
  | Ok value -> [ name, `String value ]
  | Error unread -> [ name, `Null; "unread", `String (code unread) ]
;;

(* What the list says of the key of a key account: [readable], or the code
   a use of the account answers with. A place that was not looked at has its
   reason in the log, where the paths of the server may be named. *)
let key_code account = function
  | Runtime_key_account_files.Key_readable -> "readable"
  | Runtime_key_account_files.Key_not_read error -> Runtime_api_key_file.read_error_code error
  | Runtime_key_account_files.Key_not_looked_at detail ->
    Log.Server.warn
      "The key file of account %s was not looked at for the list of its owner: %s"
      (Provider_account_id.to_string account)
      detail;
    "not_looked_at"
;;

(* The code of a start that wrote its intent and no record, of a removal
   and of a replacement of a key alike: the member it is under says which. *)
let start_given_up = "start_given_up"

let removal_code = function
  | Authz_provider_account.Start_given_up -> start_given_up
  | Authz_provider_account.Stayed Authz_purge_event.Key_not_removed -> "key_not_removed"
  | Authz_provider_account.Stayed Authz_purge_event.Home_not_removed -> "home_not_removed"
;;

let provider_accounts ~base_path ~config state { user_id; namespace } =
  let runtime_root = Runtime_account_home_layout.person_runtime_root ~base_path ~namespace in
  (* What an account runs on is named in its record in the authorization log. *)
  let accounts =
    List.map
      (fun ({ provider_account_id = account; kind; blocked } : Authz_provider_account.shown) ->
        let integration, of_kind =
          match kind with
          | Authz_provider_account_state.Login { integration_id } ->
            Integration_id.to_string integration_id, [ "kind", `String "login" ]
          | Authz_provider_account_state.Key { integration_id; generation } ->
            ( Integration_id.to_string integration_id
            , [ "kind", `String "key"
              ; ( "key"
                , `String
                    (key_code
                       account
                       (Runtime_key_account_files.key_state ~runtime_root ~account_id:account ~generation))
                )
              ] )
        in
        let of_blocked =
          match blocked with
          | None -> []
          | Some (Authz_provider_account.Removal removal) -> [ "removal", `String (removal_code removal) ]
          | Some Authz_provider_account.Replacement_start_given_up ->
            [ "replacement", `String start_given_up ]
        in
        (* Whether a Runtime of the account is listed is what a turn of it
           is judged by, not what the list has a word for: a reduction on
           the credential that [blocked] does not name hides the Runtimes
           all the same. *)
        let in_use = Result.is_ok (Authz_provider_account.availability state ~user_id account) in
        account, integration, in_use, of_kind @ of_blocked)
      (Authz_provider_account.shown state user_id)
  in
  (* A Runtime is made only on an account its maker owns (the log refuses
     [Account_not_theirs]). One whose account is not shown, because its
     removal is pending or went through, is not shown either, and neither is
     one on an account a removal or the start of a replacement of its key
     stopped on: its record stays, and every turn of it is refused. *)
  let runtimes =
    List.filter_map
      (fun (id, (runtime : Authz_runtime_state.runtime)) ->
        List.find_map
          (fun (account, integration, in_use, (_ : (string * Yojson.Safe.t) list)) ->
            if in_use && Provider_account_id.equal account runtime.provider_account_id
            then Some (id, runtime, integration)
            else None)
          accounts)
      (Authz_runtime.owned state user_id)
  in
  R.json
    R.Ok_200
    [ ( "provider_accounts"
      , `List
          (List.map
             (fun (account, integration, (_ : bool), facts) ->
               `Assoc
                 ((("provider_account_id", `String (Provider_account_id.to_string account)) :: facts)
                  @ [ "integration_id", `String integration ]))
             accounts) )
    ; ( "runtimes"
      , `List
          (List.map
             (fun (id, (runtime : Authz_runtime_state.runtime), integration) ->
               `Assoc
                 ([ "runtime_id", `String (Runtime_id.to_string id)
                  ; ( "provider_account_id"
                    , `String (Provider_account_id.to_string runtime.provider_account_id) )
                  ]
                  @ fact "model" model_unread_code (model_of ~config ~integration id runtime)))
             runtimes) )
    ]
;;
