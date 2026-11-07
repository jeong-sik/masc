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

let page ~nonce ~title ~body ~script =
  { R.status = R.Ok_200
  ; headers =
      [ "content-type", "text/html; charset=utf-8"
      ; "cache-control", "no-store"
      ; "referrer-policy", "no-referrer"
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

let start_form ~invite =
  String.concat
    "\n"
    [ "<form method=\"post\" action=\"/auth/github/start\">"
    ; (if invite then "<input type=\"hidden\" id=\"invite\" name=\"invite\">" else "")
    ; "<input type=\"hidden\" name=\"return_to\" value=\"/\">"
    ; "<button id=\"go\">Sign in with GitHub</button>"
    ; "</form>"
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

let invite_page ~nonce =
  page
    ~nonce
    ~title:"Invitation"
    ~body:
      ("<h1>Invitation</h1>\n<p id=\"note\">Sign in with GitHub to join this workspace.</p>\n"
       ^ start_form ~invite:true)
    ~script:invite_script
;;

let home_script =
  Printf.sprintf
    {|const out = document.getElementById("out");
const signout = document.getElementById("signout");
let csrf = null;
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
show();|}
    Authz_browser_request.csrf_header
;;

let home_page ~nonce =
  page
    ~nonce
    ~title:"Multi-account preview"
    ~body:
      ("<h1>Multi-account preview</h1>\n<pre id=\"out\">reading</pre>\n"
       ^ start_form ~invite:false
       ^ "\n<button id=\"signout\" hidden>Sign out</button>")
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

let whoami state ~now_ms request =
  match Auth_gate.decide state ~now_ms Route_access.Read_auth request with
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
