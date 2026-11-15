# Invitations on the account server

A multi-account installation runs the account server. A person joins it
through an invitation link, or because an Admin registered their identity
on the allowlist. This guide covers the routes with which an Admin issues,
lists and revokes invitations, and what they do not do yet.

The host operator makes the first Admin invitation without a server, with
`masc auth bootstrap` and `masc auth invite`. Those commands write Admin
invitations only and revoke none. The steps are in
[Setting up the account server](account-server-setup.md).

## What the routes do

| Request | Answer |
| --- | --- |
| `POST /api/v1/auth/invites` with `{"role":"member"}` or `{"role":"admin"}` | 200 with the invitation. |
| `GET /api/v1/auth/invites` | 200 with every invitation, and no token. |
| `DELETE /api/v1/auth/invites/<invite_id>` | 204 with no body. |

An issued invitation is answered as

```json
{"invite_id":"…","role":"member","expires_at_ms":1700086400000,"link":"/accounts/invite#…"}
```

- `link` is a reference on the account server. Put the address the person
  reaches the server at in front of it. The server names no address of its
  own in the answer.
- The part of `link` after `#` is the token. It is in this answer and
  nowhere else: the server keeps a digest of it. A link that is lost cannot
  be read again. Revoke the invitation and issue another.
- The invitation stays open for 24 hours, until one person joins through
  it, or until it is revoked.
- Whoever opens the link and signs in joins with the role of the
  invitation. An `admin` invitation makes an Admin.

The list is `{"invites":[…]}`, one object per invitation, revoked and used
ones included: `invite_id`, `role`, `issuer` (`{"kind":"local_operator"}` or
`{"kind":"admin","user_id":…}`), `expires_at_ms`, `status` and, for one a
person joined through, that person's `user_id`. `status` is `open`,
`expired`, `revocation_pending` (a revocation the log did not record: no one
joins through it, and revoking it again closes it), `revoked` or
`consumed`.

## Who may call them

A browser session of an Admin. The request carries the session cookie and
comes from the origin of the account server. An issue and a revoke also
have the CSRF token of the session in the `x-masc-csrf-token` header;
`GET /auth/session` answers that token as `csrf_token`. The list needs no
CSRF token. A personal access token does not issue, list or revoke
invitations.

| Status | When |
| --- | --- |
| 400 | The body is not one `role` of `member` or `admin`, or the id of the path is not an id. |
| 401 | No session. |
| 403 | No CSRF token on an issue or a revoke, another origin, or a person who is not an Admin. |
| 404 | No invitation has the id. |
| 409 | The invitation was revoked before, or a person joined through it. |
| 503 | The authorization log cannot be written now. |

An invitation that expired and that no one used is still open in the log,
and is revoked as any other.

## From the page of an Admin

Until the account console has a control for it, an Admin calls the routes
from the browser console of the page at `/`, signed in:

```js
const { csrf_token } = await (await fetch("/auth/session")).json();
const issued = await (await fetch("/api/v1/auth/invites", {
  method: "POST",
  headers: { "content-type": "application/json", "x-masc-csrf-token": csrf_token },
  body: JSON.stringify({ role: "member" }),
})).json();
new URL(issued.link, location.origin).href; // the link to hand over
```

To list them:

```js
const { invites } = await (await fetch("/api/v1/auth/invites")).json();
```

To revoke it:

```js
await fetch("/api/v1/auth/invites/" + issued.invite_id, {
  method: "DELETE",
  headers: { "x-masc-csrf-token": csrf_token },
});
```

## What is not there yet

- No screen calls the routes.
- An invitation has no other lifetime than 24 hours.
