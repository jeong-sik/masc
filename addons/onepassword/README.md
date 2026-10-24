# 1Password connector

Backend connection foundation for [#45736](https://github.com/jeong-sik/masc/issues/45736).
This package is under development. It is not yet an installable Lane Add-on,
does not yet export Keeper tools, and has not performed a real 1Password login.
The objective remains an installed connector that a Keeper uses in its existing
Browser Add-on session, through verified website sign-in and continuation.

## Ownership

`oauth.py` owns the production OAuth code/PKCE exchange and rotating tokens in a
separate operator-owned private store. Its only model-safe projection is
`Connector.status()`. `begin()` is an operator-only control: its authorization
URL must never enter a tool result, Ask text, observation, log or model context.
The HTTPS callback must authenticate the operator, capture `integration_key`
from the fragment, clear that fragment, and call `complete()` with the matching
state. Tokens use the fixed production API origin and redirects are refused.

`credentials(use)` is a backend callback, not a public tool. It retains the
connection lock through a private operation, serializes rotating refreshes and
fences an interrupted exchange or refresh. Remote revocation must be confirmed
by `disconnect(revoke)` before claiming the connection is disconnected. A lost
exchange response requires remote reconciliation rather than blind replay.

The caller must give the backend a dedicated absolute 0700 directory and keep
it outside retained Lane data and Keeper work disks. Records and lock files are
0600 regular files owned by the current UID. Directory replacement, symlinks
and hard-linked files are refused. Host processes share the operator's OS UID;
this is not a claim of sandbox isolation or protection against that UID.

## Docking contract still to implement

1. An authenticated operator surface for connect, callback, approval links,
   revocation and explicit interrupted-exchange recovery. A new account must not
   borrow an earlier account's integration key.
2. A package declaration, safe exported tools, skill and installation path using
   the existing Lane Add-on discovery and host-context caller identity.
3. Supported 1Password extension loading in the original owned Chromium session.
   `createAccessRequest`, status and `fillCredential` run under that Browser
   Add-on's existing page-operation ownership. No separate CDP fill bypass.
4. During fill, all reads/screenshots on that session remain excluded. A lost
   response fences further observation until the original operation is known
   settled or that original browser has been safely retired. Never replay fill.
5. Persist safe operation identity and bind its continuation to the original
   Keeper. Lane Add-on Ask alone does not provide a Keeper continuation; its
   append-only text must not carry an authorization or approval link.
6. Verify real account approval, password/OTP sign-in, denial, owner replacement,
   cancel/unknown outcomes and resumed Keeper work. Fixture checks do not prove
   installed-runtime or real account behavior.

## Verification

Run `python3 -m unittest discover -s addons/tests -p test_onepassword_oauth.py`.
The checks use a transport fixture, never a personal account or real tokens.

Protocol references: [partner guide](https://www.1password.dev/agentic-autofill/partners),
[connect](https://www.1password.dev/agentic-autofill/partners/connect),
[extension API](https://www.1password.dev/agentic-autofill/partners/extension-api),
[Browserbase integration](https://docs.browserbase.com/integrations/1password/agentic-autofill).
These are partner preview contracts; confirm access and supported builds with
1Password before using production accounts. Client registration currently needs
a Business account and a production HTTPS callback; end-user consent uses a
separate Individual/Family account on 1password.com.
