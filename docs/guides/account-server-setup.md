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
- A workspace that is activated no longer boots as a single user.
  `masc auth off` brings back a single-user boot, with the records of the
  accounts kept read-only, and this build does not activate a workspace a
  second time. Activate a base path that you keep for the accounts, not the
  one your single-user server runs on.

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
- The server does not start when a redirect is not an https URL with a host,
  when its path is not the callback of its provider, or when its origin is
  not that of `MASC_HTTP_BASE_URL` (when that is set).

## 2. Activate the workspace and invite the first Admin

Stop any server on the workspace first. The command takes the workspace
lease.

```sh
export MASC_HTTP_BASE_URL=https://<host>
masc auth bootstrap --base-path <base> --external-store <absolute path of a new file>
```

- The external store is a file that the authorization log writes to before
  and after each change. Put it outside what the backups of the base path
  copy: a backup restored over the base path must not take the store back
  with it.
- The command prints the link of the first Admin invitation once,
  `https://<host>/accounts/invite#<token>`. The link works once and expires
  after 24 hours. Only a digest of the token is written, so a lost link
  cannot be read again.
- For a link that expired or was lost, stop the server and run
  `masc auth invite --base-path <base>`. It writes one more Admin invitation
  and revokes none. While a server runs on the workspace, the command is
  refused for the lease.

## 3. Start the account server

```sh
export MASC_HTTP_BASE_URL=https://<host>
export MASC_GITHUB_CLIENT_SECRET=<client secret>
masc start --base-path <base> --port <port>
```

- The log says that the account server listens on the port and serves the
  routes of its own table, and no route that reads the credentials of a
  single user.
- `GET /health/ready` answers `{"ready":true}`.
- `masc restart` replaces it as it replaces a single-user server.

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

## 6. What a person connects

- A person connects a subscription of a client that the workspace declares
  as a provider in its runtime.toml (`<base>/.masc/config/runtime.toml`).
  The login of a client that runtime.toml does not declare is refused with
  400 before it starts.
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

- The GitHub OAuth App needs the callback URL
  `http://127.0.0.1/auth/github/callback`. GitHub takes a loopback redirect
  on any port.
- Open the link that bootstrap printed. The preview serves no MCP route and
  no Board route. It holds the workspace lease until Ctrl-C.

## Turn the accounts off

Stop every masc process on the workspace, run
`masc auth off --base-path <base>`, and take `account_mode` out of
`config.json`. A server then boots a single user. No turn runs for a Keeper
or on a Runtime of the accounts, and this build does not turn the accounts
on again.

## What is not there yet

- The TUI and the operator's dashboard do not connect to the account server.
- No screen issues invitations or edits the allowlist. An Admin calls the
  routes from the browser console of the page at `/`.
- `masc auth invite` writes Admin invitations only, and no command revokes
  one.
- A workspace whose accounts were turned off is not activated again.
