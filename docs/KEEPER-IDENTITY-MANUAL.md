---
status: runbook
---

# Attaching a work service to a Keeper

[한국어](KEEPER-IDENTITY-MANUAL.ko.md)

Attach a service -- Jira, Notion, Google Sheets -- to one Keeper and that
service's tools appear on that Keeper's surface. Attaching is one approval in
a browser; what comes back is stored as that Keeper's own secret. No other
Keeper can use it.

Seventy-seven services are declared under `config/identity/`. The list is on the
screen, so it is not repeated here.

## Two cases

| | Services | Setup |
|---|---|---|
| **Just works** | 58 -- Atlassian, Linear, Notion, Sentry, Stripe, Algolia, Perplexity, Replicate … | none (Enter immediately opens browser) |
| **App first** | Slack, GitHub, Figma, Google's eight, and others | one app per service (`A` or `a` key to configure) |

What separates them: the first group lets masc register a client when it
needs one. The second does not offer that. Google does not do it at all, and
Figma's endpoint answers 403 to anyone who asks. Pressing Enter or `A`/`a` on
an unconfigured service in this group opens the app configuration form directly
in the TUI (Client ID, Client Secret, Scopes).

## The ones that just work

**TUI**

```
Keepers → pick a keeper → [ or ] in the right pane to reach Identity
arrows to pick a service → enter
```

A browser opens. If it does not, the URL is printed on the pane. Approve, come
back, and the tab notices on its own -- no refresh needed.

Digits `1`-`9` jump to the first nine. Past that the arrows are the way.

**Dashboard**

`업무 서비스 연결` on the Keeper page, then `연결`.

## The ones needing an app

Register this masc's callback as the app's **redirect URI**:

```
<this server's base URL>/api/v1/keepers/oauth/callback
```

Then hand over the id and secret:

- Dashboard: `내 앱 쓰기` on that service's row
- Directly: `POST /api/v1/keepers/oauth/client`
  `{"provider":"slack","client_id":"…","client_secret":"…"}`

This belongs to the whole masc, not to one Keeper, so it is entered once. The
answer says whether a secret is on file and never what it is.

**Google's eight share one app.** Make one OAuth client in a Cloud project,
enter it against any one of them, and Gmail, Drive, Docs, Sheets, Slides,
Calendar, Chat and Contacts all read it. A client belongs to an authorization
server rather than to a resource, and all eight sit behind the same
`accounts.google.com`.

**Slack and GitHub need one more thing.** masc refuses a token answer that
carries neither an expiry nor a refresh token. Turn on token rotation for the
Slack app, token expiration for the GitHub app. Without it the approval
succeeds and the last step does not.

### In order

**0. Settle the callback URL first**

What goes in the app is this:

```
<this masc's base URL>/api/v1/keepers/oauth/callback
```

`MASC_HTTP_BASE_URL` decides the base URL; without it, it comes from the bind
address. The current value is the `url` field of `/.well-known/agent.json`.

**Slack requires that URL to be https.** Its documentation says a "Redirect
URL must also use HTTPS", so `http://127.0.0.1:8935/...` cannot be entered in
the app at all. To use Slack, point `MASC_HTTP_BASE_URL` at an https address
that reaches this server and restart. That value does more than the callback:
it is also the Host the server will answer to, and a request arriving through
a tunnel it does not recognise is refused with
`request_authority_untrusted`.

Google and Figma do not document whether they take an http local address. Try
the current one, and fall back to the same https address if refused.

**1. Slack**

1. Create an app at `api.slack.com/apps`.
2. OAuth & Permissions → Redirect URLs → add the callback.
3. **Turn on token rotation.** masc refuses an answer carrying neither an
   expiry nor a refresh token, so without it the consent succeeds and the
   exchange does not.
4. Set the user token scopes you want.
5. Copy the Client ID and Client Secret from Basic Information.
6. Dashboard → that Keeper → `업무 서비스 연결` → `내 앱 쓰기` on the Slack row.
7. Press Slack to connect.

**2. Figma**

1. Create an app at `figma.com/developers/apps`.
2. Add the callback as a Redirect URL.
3. Copy the Client ID and Client Secret. **The secret is shown once.**
4. Save them under `내 앱 쓰기`.
5. Press Figma to connect.

**3. GitHub**

As Slack, with an OAuth App: callback, **token expiration on**, then the id
and secret.

**4. Google — one app for eight**

1. Google Cloud Console → your project → APIs & Services → Credentials.
2. Create an OAuth client ID (Web application).
3. Add the callback under Authorized redirect URIs.
4. Enter the id and secret under `내 앱 쓰기` **once**. Whether you enter it
   against Gmail or Sheets, all eight read it.
5. Press each product you want. One app, but **one consent per product** --
   each asks for its own scopes.

## Once attached

Tool names read `<service>_<original name>`, so fetching a Jira issue is
`atlassian_getJiraIssue`. Two services using the same name do not collide.

The tool list is read once, when the service attaches. Nothing re-reads it on
a timer -- press `R` (`도구 새로고침` on the dashboard) when a service has
added tools.

Tokens renew before they expire, by the margin the declaration names.

A tool the service does not mark read-only lands in the approval queue. A
service that annotates nothing puts all of its tools there, so decide the
Keeper's approval posture alongside attaching it.

## When it does not work

The message names the cause.

| Message | Meaning | What to do |
|---|---|---|
| `offers no registration endpoint` | one of the app-first services | see above |
| `publishes no S256` | the server does not do PKCE | cannot be attached |
| `could not find out where authorization lives` | the service publishes no metadata | check the URL |
| `the provider refused the exchange` | the service said no | read the service's own reason, which follows |
| `returned no refresh token` | rotation is off on the app | turn it on |
| `callback echoed a state this exchange did not send` | the approval window sat too long, or the server restarted | press it again |

## Where things are kept

| What | Where |
|---|---|
| access token / expiry | environment entries in that Keeper's secrets (the declaration names them) |
| refresh token | a file entry in that Keeper's secrets |
| client id / secret | `.masc/identity/<client_group>/` -- shared by the whole masc |
| tool catalog | `.masc/identity/catalogs/<keeper>/<service>.json` |

## Adding one more service

Drop a TOML into `config/identity/` and rebuild. No OCaml. The file name and
`id` must match.

| Field | |
|---|---|
| `id` | one path component, same as the file name |
| `label` | what the screen calls it |
| `mcp_url` | the MCP endpoint, https only |
| `access_token_env` / `expires_at_env` | environment entry names for the token |
| `refresh_token_file` | absolute container path for the refresh token |
| `renew_before_sec` | how far before expiry to exchange again |
| `client_group` | which app to share; defaults to `id` |
| `[authorize_params]` | anything the service asks for beyond the specs |

Not in the file: the authorize, token and registration endpoints, the scopes,
and whether a secret is needed. All of that comes from what the service
publishes, so none of it can go stale here.

## See also

| Document | For |
|---|---|
| [`docs/KEEPER-USER-MANUAL.md`](KEEPER-USER-MANUAL.md) | making and running Keepers |
| [`docs/rfc/RFC-0392-keeper-identity-for-oauth-services.md`](rfc/RFC-0392-keeper-identity-for-oauth-services.md) | why it is built this way |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | dashboard write access |
