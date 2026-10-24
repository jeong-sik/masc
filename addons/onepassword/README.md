# 1Password connector

Backend connection foundation for [#45736](https://github.com/jeong-sik/masc/issues/45736).
This package is under development. It exports safe connection status through a
native Lane Add-on. Browser sign-in and Keeper continuation are not yet connected,
and it has not performed a real 1Password login.
The objective remains an installed connector that a Keeper uses in its existing
Browser Add-on session, through verified website sign-in and continuation.

## Ownership

`oauth.py` owns the production OAuth code/PKCE exchange and rotating tokens in a
separate operator-owned private store. Its only model-safe projection is
`Connector.status()`. `begin()` is an operator-only control: its authorization
URL must never enter a public tool result, Ask text, observation, log or model context.
The HTTPS callback must authenticate the operator, capture `integration_key`
from the fragment, clear that fragment, and call `complete()` with the matching
state. Tokens use the fixed production API origin and redirects are refused.

`credentials(use, expected_connection_id=...)` is a backend callback, not a public
tool. A browser operation pins `connection_identity()` at creation and retains
that identity through its lifetime; reconnecting cannot move it to a new account.
The callback retains the
connection lock through a private operation, serializes rotating refreshes and
fences an interrupted exchange or refresh. Remote revocation must be confirmed
by `disconnect(revoke)` before claiming the connection is disconnected. A lost
exchange response requires remote reconciliation rather than blind replay.

The caller must give the backend a dedicated absolute 0700 directory and keep
it outside retained Lane data and Keeper work disks. Records and lock files are
0600 regular files owned by the current UID. Directory replacement, symlinks
and hard-linked files are refused. Host processes share the operator's OS UID;
this is not a claim of sandbox isolation or protection against that UID.

## Private connection controls

The package now advertises the non-exportable `lane_operator` port for `view`,
`connect`, `complete` and transaction-pinned `cancel`. The host's existing Add-on
panel provides its connection form through the [private operator control
contract](../../docs/design/lane-addon-operator-controls.md). Register the exact
HTTPS URL `<your MASC origin>/addons/oauth/callback` with 1Password. The callback
fragment is cleared in the return page and sent through authenticated private
POST; no tokens or PKCE verifier are returned to that page.

These changes are source implementation, not an installed-host or real-account
connection result. The previously installed development package still provides
status only.

## Docking contract still to implement

`login.py` now implements a private durable lifecycle on the original companion
socket. It pins caller/account/Browser/tab, records intent before requests and
fills, keeps approval links and references in a separate private journal, and
never reconnects or replays an interrupted fill. Explicit next-page fills retain
the same grant for username/password/OTP pages. `finish` releases that grant;
its public result does not certify website authentication. A process lease
prevents another engine from recovering an active owner's operations. Restart
records lost original bindings as unknown rather than adopting a new session.

The approval checker follows the [vendor schedule](https://docs.browserbase.com/integrations/1password/agentic-autofill):
the private link can be retrieved again, and a separate opened acknowledgement
starts the five-second wait. It uses the declared
2/5/10-second windows, pauses for the user after two minutes and respects a
one-minute rate-limit wait. Pausing does not expire the task or create another
request. The engine supplies individual steps; its worker tools, private approval
UI, scheduler and Keeper continuation are still to be connected.

The Browser private wire and original-CDP extension loader are now source
implementation. Package-owned `prepare.js` waits for extension readiness and
enables whole-browser agentic mode while the page slot remains held.
`autofill.js` runs request/status/fill, matches grants by entry identity and
rechecks the exact Chrome tab before filling. A fill failure after entry fences
the original session. Their results stay on the private backend path; these
programs are not model tools. The independent host socket broker and two-phase
Python client are [source implementation](../../docs/design/lane-addon-companion-broker.md).
Runtime/private-context authority wiring is also source implementation. The
package negotiates no companion exports until its login engine is connected to
worker tools and continuation. Installed-host execution and real account
verification remain unfinished.

1. Extend the private connection controls with approval links, confirmed remote
   revocation and explicit interrupted-exchange recovery. A new account must not
   borrow an earlier account's integration key.
2. Complete the package's login tools through existing Lane Add-on discovery
   and host-context caller identity.
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

Run `python3 -m unittest discover -s addons/tests -p 'test_onepassword_*.py'`.
Run `node --test addons/tests/test_onepassword_programs.mjs` for the actual
extension programs against fake APIs (eight scenarios passed).
The checks use transport fixtures and actual MCP subprocesses, never a personal
account or real tokens. The private callback checks also verify that public
status/observations contain none of the fixture OAuth material.
Login-engine tests use real private files and fabricated credential/Browser
edges, including one real Unix-socket request/status/fill/release
flow. They do not execute Chrome, the OCaml broker or a real 1Password account.

## Install the development status connector

Python 3.11 or later and the installed `masc-native-addon-launcher` are required.
Use the [example declaration](../../docs/examples/lane-addons/onepassword.toml),
resolve `manifest_path` relative to its installed location, and save it under the
runtime's resolved `lane-addons` directory. This package is a normal MCP Add-on;
it does not declare a second `service = "browser"` or replace the Browser owner.
Its skill and `onepassword_status` export are discovered through ordinary Add-on
installation. Configuration/state failure reports unavailable, never connected.

The operator may provision `connection-config.json` next to `server.py`, owned
by their UID with mode 0600, containing exactly `client_id`, `client_secret_file`,
`redirect_uri` and `store_directory`. Both file/directory paths must be absolute.
The client secret file must be an owned regular 0600 file. The store must be a
dedicated 0700 directory outside Lane retention and agent work disks. Avoid
putting a credential value in the declaration, package skill or config document.
No configuration is required to discover the tool and observe `not_configured`.

Protocol references: [partner guide](https://www.1password.dev/agentic-autofill/partners),
[connect](https://www.1password.dev/agentic-autofill/partners/connect),
[extension API](https://www.1password.dev/agentic-autofill/partners/extension-api),
[Browserbase integration](https://docs.browserbase.com/integrations/1password/agentic-autofill).
These are partner preview contracts; confirm access and supported builds with
1Password before using production accounts. Client registration currently needs
a Business account and a production HTTPS callback; end-user consent uses a
separate Individual/Family account on 1password.com.
