(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module R = Login_routes

let github_authorize_origin = "https://github.com"

(* The start of a login answers a 303 to GitHub, and a browser checks
   [form-action] on that redirect too. *)
let policy ~nonce =
  Printf.sprintf
    "default-src 'none'; script-src %s; %s; connect-src 'self'; form-action 'self' %s; \
     base-uri 'none'; frame-ancestors 'none'"
    (Account_page.Nonce.source nonce)
    (Account_page.style_source ~nonce)
    github_authorize_origin
;;

(* Under no-referrer a browser sends "Origin: null" with a form POST (Fetch,
   "append a request Origin header"), and the start route refuses a null
   origin; Chromium 148 did so on 2026-11-08. same-origin keeps the origin on
   the form and still sends no Referer to GitHub. *)
let referrer_policy = "referrer-policy", "same-origin"

let page ~nonce ~title ~body ~script =
  { R.status = R.Ok_200
  ; headers =
      [ "content-type", "text/html; charset=utf-8"
      ; "cache-control", "no-store"
      ; referrer_policy
      ; "content-security-policy", policy ~nonce
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
           ; Printf.sprintf "<script %s>%s</script>" (Account_page.Nonce.attribute nonce) script
           ])
  }
;;

(* The form is the same whether the server has a GitHub login client or
   not, so the scripts of the pages find its elements either way. Without a
   client the start is a 404, and the button cannot be pressed. *)
let no_github_login =
  "이 서버에는 GitHub 로그인이 설정되어 있지 않아요. 이 서버를 운영하는 사람에게 알려 주세요."
;;

(* [label] is what the button says: each page names what the login does
   there. *)
let start_form ~invite ~github ~label =
  String.concat
    "\n"
    [ "<form method=\"post\" action=\"/auth/github/start\">"
    ; (if invite then "<input type=\"hidden\" id=\"invite\" name=\"invite\">" else "")
    ; "<input type=\"hidden\" name=\"return_to\" value=\"/\">"
    ; Printf.sprintf
        "<button id=\"go\" class=\"primary block\"%s>%s</button>"
        (if github then "" else " disabled aria-describedby=\"go-note\"")
        label
    ; "</form>"
    ; (if github then "" else "<p id=\"go-note\" class=\"callout\">" ^ no_github_login ^ "</p>")
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
  document.getElementById("accept").hidden = true;
  document.getElementById("note").textContent =
    "새 초대 링크를 불러오고 있어요. 화면이 바뀌지 않으면 새로고침해 주세요.";
  location.reload();
});
document.getElementById("invite").value = token;
if (token === "") {
  document.title = "이 주소에는 초대 정보가 없어요";
  document.getElementById("title").textContent = document.title;
  document.getElementById("note").textContent =
    "받은 초대 링크 전체를 그대로 다시 열어 주세요. 주소 끝의 # 뒤 글자까지 있어야 해요.";
  document.getElementById("accept").hidden = true;
  document.getElementById("back").hidden = false;
}|}
;;

let invite_page ~nonce ~github =
  page
    ~nonce
    ~title:"MASC 초대"
    ~body:
      (String.concat
         "\n"
         [ "<div class=\"narrow\">"
         ; "<div class=\"card\">"
         ; "<h1 id=\"title\">초대를 받았어요</h1>"
         ; "<p id=\"note\">GitHub 계정으로 로그인하면 초대를 수락하고 이 서버를 쓸 수 있어요.</p>"
         ; "<div id=\"accept\">"
         ; start_form ~invite:true ~github ~label:"GitHub로 로그인하고 수락하기"
         ; "<ul class=\"notes\">"
         ; "<li>초대 링크는 한 번만 쓸 수 있어요.</li>"
         ; "<li>기한이 지나면 쓸 수 없어요.</li>"
         ; "</ul>"
         ; "</div>"
         ; "<p id=\"back\" hidden><a class=\"button block\" href=\"/\">로그인 화면으로</a></p>"
         ; "</div>"
         ; "</div>"
         ])
    ~script:invite_script
;;

(* The subscription connect route of the server, which the preview serves
   for a person (plan D1-4), and the list of what a person owns. *)
let connect_path = "/api/v1/setup/accounts/login"
let connect_prefix = connect_path ^ "/"
let provider_accounts_path = "/api/v1/auth/provider-accounts"
let verify_path = "/api/v1/setup/accounts/verify"

(* The session routes answer one of three things, and the page has a view for
   each: a session (200), no session (401), and anything else, which leaves
   that unknown. The sign-in is shown for a 401 alone. Shown for a server that
   cannot tell, it would say to a signed-in person that the session is over.

   A sign-out ends the session when the server says so (204) or finds none
   (401). The page loads itself again then, so nothing that it listed for the
   person stays in it. After any other answer the page reads the session
   again: a session that is still open is told that the sign-out did not
   happen, and the next request carries the CSRF token that was read last. A
   session that cannot be read hides the button that was pressed, so the
   focus moves to the link that opens the page again. *)
let home_script =
  Printf.sprintf
    {|const out = document.getElementById("out");
const signout = document.getElementById("signout");
const accounts = document.getElementById("accounts");
const integration = document.getElementById("integration");
const transcript = document.getElementById("transcript");
const reply = document.getElementById("reply");
const account = document.getElementById("account");
const model = document.getElementById("model");
const verdict = document.getElementById("verdict");
const runtimes = document.getElementById("runtimes");
const keepers = document.getElementById("keepers");
const keeper = document.getElementById("keeper");
const keeperRuntime = document.getElementById("keeper-runtime");
const keeperVerdict = document.getElementById("keeper-verdict");
const turnMessage = document.getElementById("turn-message");
const turnAnswer = document.getElementById("turn-answer");
const pats = document.getElementById("pats");
const patScope = document.getElementById("pat-scope");
const patExpiry = document.getElementById("pat-expiry");
const patToken = document.getElementById("pat-token");
const patId = document.getElementById("pat-id");
const patVerdict = document.getElementById("pat-verdict");
const signin = document.getElementById("signin");
const signedIn = document.getElementById("signed-in");
const unread = document.getElementById("unread");
const reopen = document.getElementById("reopen");
const allowSection = document.getElementById("allowlist");
const allowProvider = document.getElementById("allow-provider");
const allowIdentity = document.getElementById("allow-identity");
const allowId = document.getElementById("allow-id");
const allowVerdict = document.getElementById("allow-verdict");
let csrf = null;
let loginId = null;
async function read(path) {
  const answer = await fetch(path);
  const text = await answer.text();
  try { return [answer, JSON.parse(text)]; } catch (_) { return [answer, { error: text }]; }
}
const unanswered = [{ ok: false, status: 0 }, { error: "the server did not answer" }];
async function show() {
  const [session, s] = await read("/auth/session").catch(() => unanswered);
  const [who, w] = await read("/api/v1/auth/whoami").catch(() => unanswered);
  const view = session.ok ? "signed_in" : (session.status === 401 ? "signed_out" : "unknown");
  csrf = session.ok ? s.csrf_token : null;
  signout.hidden = !session.ok;
  signin.hidden = view !== "signed_out";
  unread.hidden = view !== "unknown";
  signedIn.hidden = view !== "signed_in";
  allowSection.hidden = !(session.ok && w.role === "admin");
  out.textContent =
    (session.ok
      ? "session of " + s.user_id + " until " + new Date(s.expires_at_ms).toISOString()
      : view + " (" + session.status + "): " + s.error) +
    "\nwhoami (" + who.status + "): " + JSON.stringify(w);
  return view;
}
signout.addEventListener("click", async () => {
  const status = await fetch("/auth/logout", { method: "POST", headers: { "%s": csrf } })
    .then((answer) => answer.status, () => "no answer");
  const view = status === 204 || status === 401 ? "signed_out" : await show();
  if (view === "signed_out") location.reload();
  if (view === "unknown") reopen.focus();
  if (view === "signed_in") {
    out.textContent =
      "The sign-out did not happen (" + status + "), and the session is still open.\n" + out.textContent;
  }
});
async function listAccounts() {
  const [answer, json] = await read("%s");
  accounts.textContent = answer.ok
    ? (json.provider_accounts.length === 0 ? "none"
       : json.provider_accounts.map((a) => a.provider_account_id).join("\n"))
    : "(" + answer.status + "): " + json.error;
  runtimes.textContent = answer.ok
    ? (json.runtimes.length === 0 ? "none"
       : json.runtimes.map((r) => r.runtime_id + " on " + r.provider_account_id).join("\n"))
    : "";
  if (answer.ok) {
    fill(account, json.provider_accounts.map((a) => a.provider_account_id));
    fill(keeperRuntime, json.runtimes.map((r) => r.runtime_id));
  }
}
function fill(select, values) {
  const previous = select.value;
  select.replaceChildren(...values.map((value) => {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = value;
    return option;
  }));
  select.value = values.includes(previous) ? previous : (values.length === 0 ? "" : values[values.length - 1]);
}
function post(path, body) {
  return fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json", "%s": csrf },
    body: JSON.stringify(body)
  });
}
function frame(text) {
  const event = /^event: (.*)$/m.exec(text);
  const data = /^data: (.*)$/m.exec(text);
  if (event === null || data === null) return;
  const json = JSON.parse(data[1]);
  if (event[1] === "output") { transcript.textContent += json.text; return; }
  if (event[1] === "started") loginId = json.login_id;
  transcript.textContent += "\n[" + event[1] + "] " + (json.message || json.status || "") + "\n";
}
document.getElementById("connect").addEventListener("click", async () => {
  transcript.textContent = "";
  const answer = await post("%s", { integration_id: integration.value });
  if (!answer.ok) {
    transcript.textContent = "connect (" + answer.status + "): " + await answer.text();
    return;
  }
  const reader = answer.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    let cut;
    while ((cut = buffer.indexOf("\n\n")) >= 0) {
      frame(buffer.slice(0, cut));
      buffer = buffer.slice(cut + 2);
    }
  }
  await listAccounts();
});
document.getElementById("send").addEventListener("click", async () => {
  const path = "%s" + loginId + "/input";
  const text = await post(path, { kind: "text", text: reply.value });
  const enter = await post(path, { kind: "key", key: "enter" });
  transcript.textContent += "\n[sent] " + text.status + " " + enter.status + "\n";
  reply.value = "";
});
document.getElementById("verify").addEventListener("click", async () => {
  verdict.textContent = "calling the account";
  const answer = await post("%s", { provider_account_id: account.value, model: model.value });
  verdict.textContent = "verify (" + answer.status + "): " + await answer.text();
  await listAccounts();
});
async function listKeepers() {
  const [answer, json] = await read("%s");
  keepers.textContent = answer.ok
    ? (json.keepers.length === 0 ? "none"
       : json.keepers.map((k) =>
           k.keeper_id + " on " + (k.runtime_id === null ? "no Runtime" : k.runtime_id)).join("\n"))
    : "(" + answer.status + "): " + json.error;
}
document.getElementById("make-keeper").addEventListener("click", async () => {
  const answer = await post("%s", { keeper_id: keeper.value });
  keeperVerdict.textContent = "make (" + answer.status + "): " + await answer.text();
  await listKeepers();
});
document.getElementById("assign").addEventListener("click", async () => {
  const answer = await post("%s", { keeper_id: keeper.value, runtime_id: keeperRuntime.value });
  keeperVerdict.textContent = "assign (" + answer.status + "): " + await answer.text();
  await listKeepers();
});
document.getElementById("run-turn").addEventListener("click", async () => {
  turnAnswer.textContent = "running the Keeper";
  const answer = await post("%s", { keeper_id: keeper.value, message: turnMessage.value });
  const text = await answer.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) {}
  turnAnswer.textContent = answer.ok && json !== null
    ? json.keeper_id + " on " + json.runtime_id + " (" + json.model + "):\n" + json.text
    : "run (" + answer.status + "): " + text;
});
async function listPats() {
  function expiryLabel(milliseconds) {
    const date = new Date(milliseconds);
    return Number.isNaN(date.getTime())
      ? String(milliseconds) + " ms since epoch"
      : date.toISOString();
  }
  const [answer, json] = await read("%s");
  pats.textContent = answer.ok
    ? (json.pats.length === 0 ? "none"
       : json.pats.map((p) =>
           p.pat_id + " " + p.status + " " + JSON.stringify(p.scope) +
           (p.expires_at_ms === null ? "" : " until " + expiryLabel(p.expires_at_ms))).join("\n"))
    : "(" + answer.status + "): " + json.error;
}
document.getElementById("issue-pat").addEventListener("click", async () => {
  let scope = null;
  try { scope = JSON.parse(patScope.value); } catch (_) {
    patToken.textContent = "the scope is not JSON";
    return;
  }
  const expiryText = patExpiry.value.trim();
  const expiry = expiryText === "" ? null : new Date(expiryText).getTime();
  if (expiry !== null && !Number.isSafeInteger(expiry)) {
    patToken.textContent = "the expiry is not a date and time";
    return;
  }
  const answer = await post("%s", { scope: scope, expires_at_ms: expiry });
  const text = await answer.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) {}
  if (answer.ok && json !== null) {
    patId.value = json.pat_id;
    patToken.textContent =
      "Shown once. Who it acts as:\ncurl -H 'Authorization: Bearer " + json.token + "' " +
      location.origin + "/api/v1/auth/whoami";
  } else {
    patToken.textContent = "issue (" + answer.status + "): " + text;
  }
  await listPats();
});
document.getElementById("revoke-pat").addEventListener("click", async () => {
  const answer = await fetch("%s/" + encodeURIComponent(patId.value), {
    method: "DELETE",
    headers: { "%s": csrf }
  });
  patVerdict.textContent = "revoke (" + answer.status + "): " + await answer.text();
  await listPats();
});
function allowBody() {
  const identity = allowIdentity.value.trim();
  if (allowProvider.value === "github") {
    const userId = Number(identity);
    return identity !== "" && Number.isSafeInteger(userId) && userId > 0
      ? { provider: "github", user_id: userId }
      : null;
  }
  return identity === "" ? null : { provider: "google", sub: identity };
}
document.getElementById("allow-add").addEventListener("click", async () => {
  const body = allowBody();
  if (body === null) {
    allowVerdict.textContent = allowProvider.value === "github"
      ? "A GitHub user id is a whole number above 0: gh api users/LOGIN -q .id"
      : "A Google sub is not empty.";
    return;
  }
  allowVerdict.textContent = "registering";
  const answer = await post("%s", body);
  const text = await answer.text();
  let json = null;
  try { json = JSON.parse(text); } catch (_) {}
  if (answer.ok && json !== null) {
    allowId.value = json.registration_id;
    allowVerdict.textContent =
      "Allowed. Registration id " + json.registration_id +
      (json.previously_deleted ? "\nA deleted account had this identity." : "");
  } else {
    allowVerdict.textContent = "allow (" + answer.status + "): " + text;
  }
});
document.getElementById("allow-remove").addEventListener("click", async () => {
  const answer = await fetch("%s/" + encodeURIComponent(allowId.value), {
    method: "DELETE",
    headers: { "%s": csrf }
  });
  allowVerdict.textContent = answer.ok
    ? "Removed."
    : "remove (" + answer.status + "): " + await answer.text();
});
show().then(async (view) => {
  if (view === "signed_in") {
    await listAccounts();
    await listKeepers();
    await listPats();
  }
});|}
    Authz_browser_request.csrf_header
    provider_accounts_path
    Authz_browser_request.csrf_header
    connect_path
    connect_prefix
    verify_path
    Auth_preview_keeper.keepers_path
    Auth_preview_keeper.keepers_path
    Auth_preview_keeper.assign_path
    Auth_preview_keeper.turn_path
    Login_pat_routes.path
    Login_pat_routes.path
    Login_pat_routes.path
    Authz_browser_request.csrf_header
    Login_allowlist_routes.path
    Login_allowlist_routes.path
    Authz_browser_request.csrf_header
;;

(* A section is named by its heading, so a screen reader lists the page by
   the same words that a sighted person scans. *)
let section ~id ?(attrs = "") heading fields =
  String.concat
    "\n"
    ([ Printf.sprintf "<section aria-labelledby=\"%s-heading\"%s>" id attrs
     ; Printf.sprintf "<h2 id=\"%s-heading\">%s</h2>" id heading
     ]
     @ fields
     @ [ "</section>" ])
;;

let home_page ~nonce ~github =
  page
    ~nonce
    ~title:"MASC 계정"
    ~body:
      (String.concat
         "\n"
         [ "<div id=\"signin\" class=\"narrow\">"
         ; "<div class=\"card\">"
         ; "<h1>로그인</h1>"
         ; "<p>초대받은 계정으로 로그인하면 내 구독을 연결하고 내 Keeper를 만들 수 있어요.</p>"
         ; start_form ~invite:false ~github ~label:"GitHub로 계속하기"
         ; "</div>"
         ; "<p class=\"hint center\">초대 링크를 받았다면 그 링크를 먼저 열어 주세요. 초대는 이 서버를 운영하는 사람에게 요청할 수 있어요.</p>"
         ; "</div>"
           (* Shown in place of the sign-in when the session routes did not
              say whether a session is open. It replaces what the page showed
              first, so it is an alert: a screen reader says it as it
              appears. *)
         ; "<div id=\"unread\" class=\"narrow\" role=\"alert\" hidden>"
         ; "<div class=\"card\">"
         ; "<h1>로그인 상태를 확인하지 못했어요</h1>"
         ; "<p>서버가 지금 로그인 상태를 알려 주지 못해요. 로그인은 그대로일 수 있어요. 잠시 뒤에 다시 열어 주세요.</p>"
         ; "<p><a id=\"reopen\" class=\"button block\" href=\"/\">다시 열기</a></p>"
         ; "</div>"
         ; "<p class=\"hint center\">계속 이러면 이 서버를 운영하는 사람에게 알려 주세요.</p>"
         ; "</div>"
           (* What a signed-in person uses, in English. The line that shows
              what the session routes answered is inside it, so a browser with
              no session sees the sign-in and no answer of a route. *)
         ; "<div id=\"signed-in\" lang=\"en\" hidden>"
         ; "<h1>MASC accounts</h1>"
         ; "<pre id=\"out\" role=\"status\">reading</pre>"
         ; "<button id=\"signout\">Sign out</button>"
         ; section
             ~id:"allowlist"
             ~attrs:" id=\"allowlist\" hidden"
             "Let someone join"
             [ "<label>Provider <select id=\"allow-provider\"><option value=\"github\">GitHub</option><option value=\"google\">Google</option></select></label>"
             ; "<label>GitHub user id, or Google sub <input id=\"allow-identity\" autocomplete=\"off\" aria-describedby=\"allow-hint\"></label>"
             ; "<p id=\"allow-hint\">A GitHub user id is a number: gh api users/LOGIN -q .id</p>"
             ; "<button id=\"allow-add\">Allow</button>"
             ; "<label>Registration id <input id=\"allow-id\"></label>"
             ; "<button id=\"allow-remove\">Remove</button>"
             ; "<pre id=\"allow-verdict\" role=\"status\"></pre>"
             ]
         ; section
             ~id:"subscriptions"
             "My subscriptions"
             [ "<pre id=\"accounts\">reading</pre>"
             ; "<label>Integration (a provider of runtime.toml) <input id=\"integration\"></label>"
             ; "<button id=\"connect\">Connect</button>"
             ; "<pre id=\"transcript\" role=\"log\"></pre>"
             ; "<label>Answer the login <input id=\"reply\" autocomplete=\"off\"></label>"
             ; "<button id=\"send\">Send</button>"
             ]
         ; section
             ~id:"verify"
             "Call my subscription once"
             [ "<label>Account <select id=\"account\"></select></label>"
             ; "<label>Model (bound to the integration in runtime.toml) <input id=\"model\"></label>"
             ; "<button id=\"verify\">Verify</button>"
             ; "<pre id=\"verdict\" role=\"status\"></pre>"
             ]
         ; section ~id:"runtimes" "My Runtimes" [ "<pre id=\"runtimes\">reading</pre>" ]
         ; section
             ~id:"keepers"
             "My Keepers"
             [ "<pre id=\"keepers\">reading</pre>"
             ; "<label>Keeper name <input id=\"keeper\"></label>"
             ; "<button id=\"make-keeper\">Make</button>"
             ; "<label>Runtime (one of My Runtimes) <select id=\"keeper-runtime\"></select></label>"
             ; "<button id=\"assign\">Assign</button>"
             ; "<pre id=\"keeper-verdict\" role=\"status\"></pre>"
             ; "<label>Message to the Keeper <input id=\"turn-message\" autocomplete=\"off\"></label>"
             ; "<button id=\"run-turn\">Run</button>"
             ; "<pre id=\"turn-answer\" role=\"status\"></pre>"
             ]
         ; section
             ~id:"pats"
             "My PATs"
             [ "<pre id=\"pats\">reading</pre>"
             ; "<label>Scope <textarea id=\"pat-scope\" rows=\"2\" cols=\"72\">"
               ^ {|{"runtimes":"all","channels":["direct"],"allowed_effects":["read_state"]}|}
               ^ "</textarea></label>"
             ; "<label>Expires (your local time, empty for none) <input id=\"pat-expiry\" type=\"datetime-local\"></label>"
             ; "<button id=\"issue-pat\">Issue</button>"
             ; "<pre id=\"pat-token\" role=\"status\"></pre>"
             ; "<label>PAT id <input id=\"pat-id\"></label>"
             ; "<button id=\"revoke-pat\">Revoke</button>"
             ; "<pre id=\"pat-verdict\" role=\"status\"></pre>"
             ]
         ; "</div>"
         ])
    ~script:home_script
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

(* Why the integration of an account is not known. *)
type integration_unread =
  | Login_receipt_missing
  | Login_receipt_unreadable

(* Why the model of a Runtime is not known. *)
type model_unread =
  | Account_integration_unread
  | Configuration_unavailable
  | Not_bound of Runtime_account_runtime.error

let integration_unread_code = function
  | Login_receipt_missing -> "login_receipt_missing"
  | Login_receipt_unreadable -> "login_receipt_unreadable"
;;

let model_unread_code = function
  | Account_integration_unread -> "account_integration_unread"
  | Configuration_unavailable -> "configuration_unavailable"
  | Not_bound error -> Runtime_account_runtime.error_code error
;;

(* The integration the login of the account named, read from its receipt
   as the connect route saved it. *)
let integration_of ~base_path user_id account =
  match
    Runtime_setup_login_receipt.load
      ~workspace:base_path
      ~actor:(Runtime_setup_login_session.Person (User_id.to_string user_id))
      ~login_id:(Provider_account_id.to_string account)
  with
  | Ok receipt -> Ok receipt.Runtime_setup_login_receipt.integration_id
  | Error Runtime_setup_login_receipt.Not_found -> Error Login_receipt_missing
  | Error Runtime_setup_login_receipt.Unavailable -> Error Login_receipt_unreadable
;;

(* The model of the binding of the account's template that makes the
   Runtime id, the binding a turn of the Runtime finds: the key of its
   [models.<id>] table, as the integrations list names it and a
   verification takes it. A turn sends that model's [api-name], which may
   be another name. A Runtime id names its binding, so only
   [template_not_declared] and [runtime_not_bound] come back. *)
let model_of ~config ~integration id (runtime : Authz_runtime_state.runtime) =
  match integration, config with
  | Error (_ : integration_unread), (_ : Runtime_schema.config option) -> Error Account_integration_unread
  | Ok (_ : string), None -> Error Configuration_unavailable
  | Ok template, Some config ->
    Runtime_account_runtime.binding_of
      config
      ~template
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

let provider_accounts ~base_path ~config state { user_id; namespace = _ } =
  (* Each receipt is read once, so an account and the Runtimes on it are
     answered from the same reading. *)
  let accounts =
    List.map
      (fun account -> account, integration_of ~base_path user_id account)
      (Authz_provider_account.owned state user_id)
  in
  (* A Runtime is made only on an account its maker owns (the log refuses
     [Account_not_theirs]), so its account is in [accounts]; were it not,
     its receipt is read as the account's would be. *)
  let integration_on account =
    match List.find_opt (fun (owned, _) -> Provider_account_id.equal owned account) accounts with
    | Some (_, integration) -> integration
    | None -> integration_of ~base_path user_id account
  in
  R.json
    R.Ok_200
    [ ( "provider_accounts"
      , `List
          (List.map
             (fun (account, integration) ->
               `Assoc
                 (("provider_account_id", `String (Provider_account_id.to_string account))
                  :: fact "integration_id" integration_unread_code integration))
             accounts) )
    ; ( "runtimes"
      , `List
          (List.map
             (fun (id, (runtime : Authz_runtime_state.runtime)) ->
               let integration = integration_on runtime.provider_account_id in
               `Assoc
                 ([ "runtime_id", `String (Runtime_id.to_string id)
                  ; ( "provider_account_id"
                    , `String (Provider_account_id.to_string runtime.provider_account_id) )
                  ]
                  @ fact "model" model_unread_code (model_of ~config ~integration id runtime)))
             (Authz_runtime.owned state user_id)) )
    ]
;;
