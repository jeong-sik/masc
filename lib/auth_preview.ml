(* HIGH-RISK-UNREVIEWED: see the interface. *)

open Authz_types
module R = Login_routes

let github_authorize_origin = "https://github.com"

(* The start of a login answers a 303 to GitHub, and a browser checks
   [form-action] on that redirect too. *)
let policy ~nonce =
  Printf.sprintf
    "default-src 'none'; script-src 'nonce-%s'; %s; connect-src 'self'; form-action 'self' %s; \
     base-uri 'none'; frame-ancestors 'none'"
    nonce
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
           [ "<main>"; body; "</main>"; Printf.sprintf "<script nonce=\"%s\">%s</script>" nonce script ])
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
       else "<button id=\"go\" disabled aria-describedby=\"go-note\">Sign in with GitHub</button>")
    ; "</form>"
    ; (if github then "" else "<p id=\"go-note\">" ^ no_github_login ^ "</p>")
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
const signin = document.getElementById("signin");
const signedIn = document.getElementById("signed-in");
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
async function show() {
  const [session, s] = await read("/auth/session");
  const [who, w] = await read("/api/v1/auth/whoami");
  csrf = session.ok ? s.csrf_token : null;
  signout.hidden = !session.ok;
  signin.hidden = session.ok;
  signedIn.hidden = !session.ok;
  allowSection.hidden = !(session.ok && w.role === "admin");
  out.textContent =
    (session.ok
      ? "session of " + s.user_id + " until " + new Date(s.expires_at_ms).toISOString()
      : "no session (" + session.status + "): " + s.error) +
    "\nwhoami (" + who.status + "): " + JSON.stringify(w);
  return session.ok;
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
  if (answer.ok) {
    fill(account, json.provider_accounts);
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
show().then(async (signedInNow) => {
  if (signedInNow) {
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
    ~title:"MASC accounts"
    ~body:
      (String.concat
         "\n"
         [ "<h1>MASC accounts</h1>"
         ; "<pre id=\"out\" role=\"status\">reading</pre>"
         ; "<div id=\"signin\">" ^ start_form ~invite:false ~github ^ "</div>"
         ; "<button id=\"signout\" hidden>Sign out</button>"
         ; "<div id=\"signed-in\" hidden>"
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
