# Setting up the account server

A workspace activated for multi-account use boots as the account server.
This guide takes an operator from a workspace to a first Admin who has
signed in. Two other guides go on from there:
[Invitations on the account server](account-server-invitations.md) and
[The MCP endpoint of a person](account-server-mcp.md).

## What the account server is

- It answers the health probes (`GET /health`, `/health/live`,
  `/health/ready`), the login routes of the login clients in `config.json`,
  a person's page at `/`, the routes of invitations and of the allowlist,
  and the MCP endpoint of a person (`POST /mcp`).
- It serves only routes that are public or that check a browser session or
  a personal access token themselves. No route of the single-user server is
  there: the TUI and the operator's dashboard do not connect to it, and it
  starts none of the operator's Keepers.
- A workspace that is activated no longer boots as a single user. Turning
  the accounts off and taking `account_mode` out of `config.json` brings
  back a single-user boot (see [Turn the accounts off](#turn-the-accounts-off)),
  and this build does not activate a workspace a second time. Activate a
  base path that you keep for the accounts, not the one your single-user
  server runs on.

## Before you start

- An https address that people open, in front of the server's port. The
  login clients take only an https redirect.
- A login client at GitHub, at Google, or at both:
  - GitHub: an OAuth App whose callback URL is
    `https://<host>/auth/github/callback`.
  - Google: an OAuth client whose redirect URI is
    `https://<host>/auth/oidc/callback`.
- `MASC_ALLOW_ANONYMOUS_MUTATIONS` off in the shell that runs the commands
  below and the server.
- One user and one home for every command below and the server.
  `masc auth bootstrap` writes an install record under
  `$XDG_CONFIG_HOME/masc/`, or `~/.config/masc/` when that is not set, and
  the record names the external store. The server and the other
  `masc auth` commands find the store only through that record. Run them
  with the same `HOME` and `XDG_CONFIG_HOME`, and do not move the base path
  afterwards. A server that cannot match the store with the authorization
  log stops (`AuthorizationUncertain`), and this build has no procedure
  that makes the two agree again.

## 1. Ask for multi-account use in config.json

Write `<base>/.masc/auth/config.json`, or add the members to the file that is
there:

```json
{
  "enabled": true,
  "require_token": true,
  "account_mode": "Multi_account",
  "github": {
    "client_id": "<client ID of the OAuth App>",
    "redirect_uri": "https://<host>/auth/github/callback",
    "client_secret_env": "MASC_GITHUB_CLIENT_SECRET"
  }
}
```

- `client_secret_env` names the environment variable that holds the client
  secret. The secret is not written in the file: the server rewrites the
  file, and backups copy it.
- `google` takes the same three members, with the redirect
  `https://<host>/auth/oidc/callback`.
- The server does not start when `client_id` is empty, when the variable
  that `client_secret_env` names is unset or empty, when a redirect is not
  an https URL with a host and no query or fragment, when its path is not
  the callback of its provider, or when its origin is not that of
  `MASC_HTTP_BASE_URL` (when that is set).
- A redirect is read as it is written. The path has to be the callback
  byte for byte: `/%61uth/github/callback` or `/auth/../auth/github/callback`
  stops the boot, because the server answers 404 on a path that only decodes
  or resolves to the callback. The scheme and the host may be in another
  case, and `:443` may be written out. A redirect with a userinfo
  (`https://name@<host>/…`), an empty port (`https://<host>:/…`) or a port
  above 65535 stops the boot.

## 2. Activate the workspace and invite the first Admin

Stop any server on the workspace first. The command takes the workspace
lease.

```sh
export MASC_HTTP_BASE_URL=https://<host>
masc auth bootstrap --base-path <base> --external-store <absolute path of a new file>
```

- The external store is a file that the authorization log writes to before
  and after each change. Its path must be absolute and outside the base
  path, and outside the directory of the authorization log when a link puts
  that directory elsewhere. The command refuses any other. Put it outside
  what the backups of the base path copy as well: a backup restored over the
  base path must not take the store back with it.
- The command prints the link of the first Admin invitation once,
  `https://<host>/accounts/invite#<token>`. The link works once and expires
  after 24 hours. Only a digest of the token is written, so a lost link
  cannot be read again.
- For a link that expired or was lost, stop the server and run
  `masc auth invite --base-path <base>` with `MASC_HTTP_BASE_URL` set as
  above. It writes one more Admin invitation and revokes none. While a
  server runs on the workspace, the command is refused for the lease.

## 3. Start the account server

```sh
export MASC_HTTP_BASE_URL=https://<host>
export MASC_GITHUB_CLIENT_SECRET=<client secret>
masc start --base-path <base> --port <port>
```

- Export the secret variable of every login client in `config.json`. A
  `google` client names its own.
- The log says that the account server listens on the port and serves the
  routes of its own table, and no route that reads the credentials of a
  single user.
- `GET /health/ready` answers `{"ready":true}`.
- `masc restart` replaces it as it replaces a single-user server. The new
  server takes the environment of the shell that runs `masc restart`, so
  export `MASC_HTTP_BASE_URL` and the client secrets there too.

## 4. Sign in as the first Admin

Open the link of step 2 and sign in with GitHub or Google. The person who
signs in through an Admin invitation becomes an Admin.

## 5. Let more people in

- **An invitation.** An Admin issues a Member or an Admin invitation and
  hands over its link. See
  [Invitations on the account server](account-server-invitations.md).
- **The allowlist.** An Admin registers an identity, and that person signs in
  at `/` with no link and becomes a Member. The request is
  `POST /api/v1/auth/allowlist` from an Admin's browser session, with the
  CSRF token, as for invitations. The body is
  `{"provider":"github","user_id":<id>}` or
  `{"provider":"google","sub":"<sub>"}`, with the members in this order.
  A GitHub login can change, so the key is the numeric user id:
  `gh api users/<login> --jq .id`. The answer names a `registration_id`;
  `DELETE /api/v1/auth/allowlist/<registration_id>` removes the entry.
- **Who is in.** An Admin's browser session reads three lists, with no
  CSRF token: `GET /api/v1/auth/allowlist` (`{"registrations": [...]}`),
  `GET /api/v1/auth/invites` (`{"invites": [...]}`, with no token) and
  `GET /api/v1/auth/members` (`{"members": [...]}`). Each item has a
  `status`. An entry that is `removal_pending`, an invitation that is
  `revocation_pending` and a member whose `held` is not empty carry a
  change the log did not record: the store holds it, nobody joins or acts
  through it, and making the same change again closes it (for a member,
  `held` names which: `revoke`, `disable` or `delete`). Anyone else gets
  403.

## 6. Declare what people connect

- Write `<base>/.masc/config/runtime.toml` by hand, with a provider for each
  client people may connect. Neither bootstrap nor the account server
  writes it, and `masc setup` refuses a workspace whose `config.json` asks
  for Multi_account. Without the file, `GET /api/v1/auth/integrations`
  answers 503 and every connection is refused with 400. The
  [runtime.toml reference](../RUNTIME-TOML-REFERENCE.md) lists its rows.
- A person connects a subscription of a client that runtime.toml declares
  as a provider. The login of a client that it does not declare is refused
  with 400 before it starts. Antigravity is refused even when it is
  declared: its credential is a copy in the setup registry, which has no
  owner.
- `GET /api/v1/auth/integrations` tells a signed-in person which
  subscriptions and models they may connect. A multi-account process calls
  the models of Claude Code. It refuses those of Codex and Muse for their
  native tools. It leaves out a model whose runtime.toml row declares no
  tool calling.
- The person makes Keepers on their own Runtimes, from their page or from
  an MCP client. See [The MCP endpoint of a person](account-server-mcp.md).
- The page at `/` is moving to `/accounts/console`.

## Try it on this machine first

`masc auth preview` serves the login routes and a person's pages on
127.0.0.1 without TLS. It needs an activated workspace. Write the
`config.json` of step 1 in a scratch base path, without `github` or
`google`: the preview makes its own login client from the flags below.

```sh
export MASC_HTTP_BASE_URL=http://127.0.0.1:8940
masc auth bootstrap --base-path <scratch base> --external-store <scratch store file>
export MASC_GITHUB_CLIENT_SECRET=<client secret>
masc auth preview --base-path <scratch base> --github-client-id <client ID>
```

- The store file follows the rule of step 2: an absolute path outside the
  scratch base path.
- The GitHub OAuth App needs the callback URL
  `http://127.0.0.1/auth/github/callback`. GitHub takes a loopback redirect
  on any port.
- Open the link that bootstrap printed. The preview also serves the MCP
  endpoint of a person, and no Board route. It holds the workspace lease
  until Ctrl-C.

## Turn the accounts off

Stop every masc process on the workspace, run
`masc auth off --base-path <base>`, and take `account_mode` out of
`config.json`. A server then boots a single user. No turn runs for a Keeper
or on a Runtime of the accounts, and this build does not turn the accounts
on again. While the homes of people remain under `.masc/accounts`, a
single-user turn that gives a client its native tools is refused on that
base path.

## What is not there yet

- The TUI and the operator's dashboard do not connect to the account server.
- No screen issues invitations, edits the allowlist or shows the lists. An
  Admin calls the routes from the browser console of the page at `/`.
- `masc auth invite` writes Admin invitations only, and no command revokes
  one.
- A workspace whose accounts were turned off is not activated again.
