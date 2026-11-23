---
status: runbook
---

# Attaching a work service to a Keeper

[한국어](KEEPER-IDENTITY-MANUAL.ko.md)

Attach a service -- Jira, Notion, Google Sheets -- to one Keeper and that
service's tools appear on that Keeper's surface. Attaching is one approval in
a browser; what comes back is stored as that Keeper's own secret. No other
Keeper can use it.

Eighty-nine services are declared under `config/identity/`. The list is on the
screen, so it is not repeated here.

## Two cases

| | Services | Setup |
|---|---|---|
| **Just works** | 69 -- Atlassian, Linear, Notion, Sentry, Stripe, Algolia, CircleCI, DeepL, Postman, Sanity … | none |
| **App first** | Slack, Figma, Google's eight, Zendesk, and others | one app per service |

What separates them: the first group lets masc register a client when it
needs one. masc registers a fresh one on every login, naming the callback the
server answers at right then, so changing the server's base URL never leaves
an older registration pointing at the old address. The second group does not
offer registration. Google does not do it at all, and
Figma's endpoint answers 403 to anyone who asks.

GitHub is neither. It attaches with the token that Keeper's GitHub CLI already
holds, so log the Keeper in first with `masc keeper-github login --keeper <name>`.

## The ones that just work

On the dashboard, open `업무 서비스 연결` on the Keeper page and press `연결`.
A new browser tab opens on the service's consent page. If it does not, the
panel shows the link.

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
3. Set the user token scopes you want.
4. Copy the Client ID and Client Secret from Basic Information.
5. Dashboard → that Keeper → `업무 서비스 연결` → `내 앱 쓰기` on the Slack row.
6. Press Slack to connect.

**2. Figma**

1. Create an app at `figma.com/developers/apps`.
2. Add the callback as a Redirect URL.
3. Copy the Client ID and Client Secret. **The secret is shown once.**
4. Save them under `내 앱 쓰기`.
5. Press Figma to connect.

**3. Google — one app for eight**

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
a timer -- press `도구 새로고침` on the dashboard when a service has added
tools.

Tokens renew before they expire, by the margin the declaration names.

A tool the service does not mark read-only lands in the approval queue. A
service that annotates nothing puts all of its tools there, so decide the
Keeper's approval posture alongside attaching it.

## Detaching a service

Send `POST /api/v1/keepers/oauth/disconnect` with an admin token and the body
`{"keeper":"<keeper>","provider":"<service id>"}`. The dashboard panel has no
detach button. The answer says what was removed and whether the service was
asked to revoke what it still holds. The two are different facts:

- **Stored tokens.** The refresh-token file entry and the access-token and
  expiry environment entries are deleted, and the tool catalog for that
  Keeper and service goes with them, so the next turn stops being handed
  those tools.
- **Provider revoke.** If the service publishes a revocation endpoint, masc
  posts the refresh token to it, best effort. The answer's `revocation.kind`
  is `revoked` when the service answered; `failed` when it refused or could
  not be reached, and the local deletion still stands; `not_published` when
  there was nowhere to send it or nothing to send -- the service publishes no
  revocation endpoint, or masc held no refresh token -- so the token is gone
  from here but the service may keep honouring it until it expires or is
  revoked from the service's own settings; `not_sent` when masc could not
  name the client the token was issued to, so no request went out.

Deleting locally and revoking at the service are not the same act. A detach
always deletes; it can only *ask* the service. If the answer says `failed`,
`not_published` or `not_sent` and the service must forget the token now,
revoke it from the service's own account settings.

A detach is not the switch. The switch (`끄기` / `켜기` on the dashboard) turns
a service off for a Keeper and keeps its token, so turning it back on needs no
new consent. Detaching forgets the token, and attaching the service again
means a new consent.

## When it does not work

The message names the cause.

| Message | Meaning | What to do |
|---|---|---|
| `offers no registration endpoint` | one of the app-first services | see above |
| `publishes no S256` | the server does not do PKCE | cannot be attached |
| `could not find out where authorization lives` | the service publishes no metadata | check the URL |
| `the provider refused the exchange` | the service said no | read the service's own reason, which follows |
| `returned no refresh token` | a warning, not a failure: the service is attached, but its token expires and cannot be renewed | attach it again when it expires |
| `callback echoed a state this exchange did not send` | the approval window sat too long, or the server restarted | press it again |

## Where things are kept

| What | Where |
|---|---|
| access token / expiry | environment entries in that Keeper's secrets (the declaration names them) |
| refresh token | a file entry in that Keeper's secrets |
| app you made (id / secret / scopes) | `.masc/identity/apps/<client_group>.json` -- shared by the whole masc |
| client a login used | `.masc/identity/clients/<keeper>/<service>.json` -- renewal and detach use this one, because a refresh token belongs to the client it was issued to |
| tool catalog | `.masc/identity/catalogs/<keeper>/<service>.json` |
| detach receipt | `.masc/identity/disconnects/<keeper>/<service>.json` |

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
| `callback` | `"loopback"` for a service that accepts only an RFC 8252 redirect, `http://127.0.0.1:<port>/api/v1/keepers/oauth/callback`; absent means this server's base URL. Measure it before writing it: registration or the authorize step refuses the public callback, and accepts the loopback one. The browser that consents has to run on the server's machine. |

Not in the file: the authorize, token and registration endpoints, the scopes,
and whether a secret is needed. All of that comes from what the service
publishes, so none of it can go stale here.

## See also

| Document | For |
|---|---|
| [`docs/KEEPER-USER-MANUAL.md`](KEEPER-USER-MANUAL.md) | making and running Keepers |
| [`docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md`](LOCAL-DASHBOARD-AUTH-RUNBOOK.md) | dashboard write access |
