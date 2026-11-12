(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module R = Login_routes

let github_authorize_origin = "https://github.com"

(* The start of a login answers a 303 to GitHub, and a browser checks
   [form-action] on that redirect too. *)
let policy ~nonce =
  Printf.sprintf
    "default-src 'none'; script-src 'nonce-%s'; connect-src 'self'; form-action 'self' %s; \
     base-uri 'none'; frame-ancestors 'none'"
    nonce
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
        ; Printf.sprintf "<script nonce=\"%s\">%s</script>" nonce script
        ; "</body>"
        ; "</html>"
        ; ""
        ]
  }
;;

(* The form is the same whether the server has a GitHub login client or
   not, so the scripts of the pages find its elements either way. Without a
   client the start is a 404, and the button cannot be pressed. *)
let no_github_login = "This server has no GitHub login."

let start_form ~invite ~github =
  String.concat
    "\n"
    [ "<form method=\"post\" action=\"/auth/github/start\">"
    ; (if invite then "<input type=\"hidden\" id=\"invite\" name=\"invite\">" else "")
    ; "<input type=\"hidden\" name=\"return_to\" value=\"/\">"
    ; (if github
       then "<button id=\"go\">Sign in with GitHub</button>"
       else "<button id=\"go\" disabled>Sign in with GitHub</button>")
    ; "</form>"
    ; (if github then "" else "<p>" ^ no_github_login ^ "</p>")
    ]
;;

(* The script takes the token from the fragment and drops the fragment from
   the address bar, so the token is in no request line and no history entry. *)
let invite_script =
  {|const token = location.hash.slice(1);
history.replaceState(null, "", location.pathname);
document.getElementById("invite").value = token;
if (token === "") {
  document.getElementById("note").textContent = "This link holds no invitation.";
  document.getElementById("go").disabled = true;
}|}
;;

let invite_page ~nonce ~github =
  page
    ~nonce
    ~title:"Invitation"
    ~body:
      ("<h1>Invitation</h1>\n<p id=\"note\">Sign in with GitHub to join this workspace.</p>\n"
       ^ start_form ~invite:true ~github)
    ~script:invite_script
;;

(* The subscription connect route of the server, which the preview serves
   for a person (plan D1-4), and the list of what a person owns. *)
let connect_path = "/api/v1/setup/accounts/login"
let connect_prefix = connect_path ^ "/"
let provider_accounts_path = "/api/v1/auth/provider-accounts"
let verify_path = "/api/v1/setup/accounts/verify"

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
let csrf = null;
let loginId = null;
async function read(path) {
  const answer = await fetch(path);
  const text = await answer.text();
  try { return [answer, JSON.parse(text)]; } catch (_) { return [answer, { error: text }]; }
}
async function show() {
  const [session, s] = await read("/auth/session");
  const [who, w] = await read("/api/v1/auth/whoami");
  csrf = session.ok ? s.csrf_token : null;
  signout.hidden = !session.ok;
  out.textContent =
    (session.ok
      ? "session of " + s.user_id + " until " + new Date(s.expires_at_ms).toISOString()
      : "no session (" + session.status + "): " + s.error) +
    "\nwhoami (" + who.status + "): " + JSON.stringify(w);
}
signout.addEventListener("click", async () => {
  const answer = await fetch("/auth/logout", { method: "POST", headers: { "%s": csrf } });
  out.textContent = "sign-out: " + answer.status;
  await show();
});
async function listAccounts() {
  const [answer, json] = await read("%s");
  accounts.textContent = answer.ok
    ? (json.provider_accounts.length === 0 ? "none" : json.provider_accounts.join("\n"))
    : "(" + answer.status + "): " + json.error;
  runtimes.textContent = answer.ok
    ? (json.runtimes.length === 0 ? "none"
       : json.runtimes.map((r) => r.runtime_id + " on " + r.provider_account_id).join("\n"))
    : "";
  if (answer.ok && json.provider_accounts.length > 0) {
    account.value = json.provider_accounts[json.provider_accounts.length - 1];
  }
  if (answer.ok && json.runtimes.length > 0) {
    keeperRuntime.value = json.runtimes[json.runtimes.length - 1].runtime_id;
  }
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
  const expiry = expiryText === "" ? null : Number(expiryText);
  if (expiry !== null && !Number.isSafeInteger(expiry)) {
    patToken.textContent = "expiry must be a safe integer in epoch milliseconds";
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
show().then(listAccounts).then(listKeepers).then(listPats);|}
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
;;

let home_page ~nonce ~github =
  page
    ~nonce
    ~title:"MASC accounts"
    ~body:
      ("<h1>MASC accounts</h1>\n<pre id=\"out\">reading</pre>\n"
       ^ start_form ~invite:false ~github
       ^ "\n<button id=\"signout\" hidden>Sign out</button>\n"
       ^ String.concat
           "\n"
           [ "<h2>My subscriptions</h2>"
           ; "<pre id=\"accounts\">reading</pre>"
           ; "<label>Integration (a provider of runtime.toml) <input id=\"integration\"></label>"
           ; "<button id=\"connect\">Connect</button>"
           ; "<pre id=\"transcript\"></pre>"
           ; "<label>Answer the login <input id=\"reply\" autocomplete=\"off\"></label>"
           ; "<button id=\"send\">Send</button>"
           ; "<h2>Call my subscription once</h2>"
           ; "<label>Account <input id=\"account\"></label>"
           ; "<label>Model (bound to the integration in runtime.toml) <input id=\"model\"></label>"
           ; "<button id=\"verify\">Verify</button>"
           ; "<pre id=\"verdict\"></pre>"
           ; "<h2>My Runtimes</h2>"
           ; "<pre id=\"runtimes\">reading</pre>"
           ; "<h2>My Keepers</h2>"
           ; "<pre id=\"keepers\">reading</pre>"
           ; "<label>Keeper name <input id=\"keeper\"></label>"
           ; "<button id=\"make-keeper\">Make</button>"
           ; "<label>Runtime (one of My Runtimes) <input id=\"keeper-runtime\"></label>"
           ; "<button id=\"assign\">Assign</button>"
           ; "<pre id=\"keeper-verdict\"></pre>"
           ; "<label>Message to the Keeper <input id=\"turn-message\" autocomplete=\"off\"></label>"
           ; "<button id=\"run-turn\">Run</button>"
           ; "<pre id=\"turn-answer\"></pre>"
           ; "<h2>My PATs</h2>"
           ; "<pre id=\"pats\">reading</pre>"
           ; "<label>Scope <textarea id=\"pat-scope\" rows=\"2\" cols=\"72\">"
             ^ {|{"runtimes":"all","channels":["direct"],"allowed_effects":["read_state"]}|}
             ^ "</textarea></label>"
           ; "<label>Expires at (ms since the epoch, empty for none) <input id=\"pat-expiry\"></label>"
           ; "<button id=\"issue-pat\">Issue</button>"
           ; "<pre id=\"pat-token\"></pre>"
           ; "<label>PAT id <input id=\"pat-id\"></label>"
           ; "<button id=\"revoke-pat\">Revoke</button>"
           ; "<pre id=\"pat-verdict\"></pre>"
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

(* The human a [Manage_own_*] route lets through. *)
let human trusted ~now_ms access ~service_refused request =
  match Auth_gate.decide trusted ~now_ms access request with
  | Error reason -> Error (refused reason)
  | Ok (Auth_gate.Authenticated { Auth_gate.principal = Principal.Human user_id; _ }) -> Ok user_id
  | Ok (Auth_gate.Authenticated { Auth_gate.principal = Principal.Service service_id; _ }) ->
    (* [decide] refuses a service on these kinds; were it not to, it still
       owns nothing. *)
    Error (refused (service_refused service_id))
  | Ok (Auth_gate.Anonymous | Auth_gate.Judged_by_route) ->
    (* These kinds need a credential, so [decide] answers neither. *)
    Error (refused Auth_gate.Credential_required)
;;

(* The human a [Manage_own_*] route lets through, with the namespace their
   admission fixed. *)
let member (trusted : Authz_zone.trusted) ~now_ms access ~service_refused request =
  match human trusted ~now_ms access ~service_refused request with
  | Error _ as refused -> refused
  | Ok user_id ->
    let state = (trusted :> Authz_zone.snapshot).Authz_zone.state in
    (match Authz_principal_state.find_membership state.Authz_state.principals user_id with
     | Some { Authz_principal_state.account_home_namespace = namespace; workspace_id = _ } ->
       Ok { user_id; namespace }
     | None ->
       (* The admission that made an active principal made its membership in
          the same record, so none is a log this build did not write. *)
       Error (R.json R.Internal_error_500 [ "error", `String "the principal has no membership" ]))
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

let keeper_owner_person trusted ~now_ms request =
  member
    trusted
    ~now_ms
    Route_access.Manage_own_keeper
    ~service_refused:(fun service_id -> Auth_gate.Service_owns_no_keeper service_id)
    request
;;

let provider_accounts state { user_id; namespace = _ } =
  R.json
    R.Ok_200
    [ ( "provider_accounts"
      , `List
          (List.map
             (fun id -> `String (Provider_account_id.to_string id))
             (Authz_provider_account.owned state user_id)) )
    ; ( "runtimes"
      , `List
          (List.map
             (fun (id, (runtime : Authz_runtime_state.runtime)) ->
               `Assoc
                 [ "runtime_id", `String (Runtime_id.to_string id)
                 ; ( "provider_account_id"
                   , `String (Provider_account_id.to_string runtime.provider_account_id) )
                 ])
             (Authz_runtime.owned state user_id)) )
    ]
;;
