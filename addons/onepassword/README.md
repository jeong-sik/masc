# 1Password connector (Experimental)

Backend connection foundation for [#45736](https://github.com/jeong-sik/masc/issues/45736).
This package is under development. Its native Lane Add-on exports login requests,
committed status, next-page fill, release and cancellation, with a separate private
operator approval surface. Its private publication transport and durable original
Keeper queue are connected in source. An isolated native candidate has executed
the status tool in a real Keeper turn. Real 1Password login and original-task
continuation remain unverified.
The objective remains an installed connector that a Keeper uses in its existing
Browser Add-on session, through verified website sign-in and continuation.

## Ownership

`oauth.py` owns the production OAuth code/PKCE exchange and rotating tokens in a
separate operator-owned private store. Its only model-safe projection is
`Connector.status()`. `begin()` is an operator-only control: its authorization
URL must never enter a public tool result, Ask text, observation, log or model context.
The HTTPS callback authenticates the operator and sends the original
`integration_key` fragment to `complete()` with the matching state and connection.
It preserves the URL/window or manual input until the backend confirms durable
capture of that original key; only then may the page clear its URL and close.
Tokens use the fixed production API origin and redirects are refused.

`credentials(use, expected_connection_id=...)` is a backend callback, not a public
tool. A browser operation pins `connection_identity()` at creation and retains
that identity through its lifetime; reconnecting cannot move it to a new account.
The callback retains the
connection lock through a private operation, serializes rotating refreshes and
fences an interrupted exchange or refresh. Remote revocation must be confirmed
by `disconnect(revoke)` before claiming the connection is disconnected. A lost
exchange response requires remote reconciliation rather than blind replay.

The caller must give the backend a dedicated absolute 0700 directory and keep
it outside retained Lane data and Keeper work disks. Tokens, PKCE state and
integration keys are encrypted by the operator's macOS Keychain or Linux
Secret Service, through the pinned `keyring` dependency. No discovered,
plaintext or third-party fallback is allowed. The directory retains only a
nonsecret active-slot reference and lock, as owned 0600 regular files.
Directory replacement, symlinks
and hard-linked files are refused. Host processes share the operator's OS UID;
this is not a claim of sandbox isolation or protection against that UID.
Writes replace the inactive protected slot, verify a read-back and then commit
the nonsecret reference. A failed inactive write leaves the active recovery authority
intact. An interrupted reference commit is recovered from the retained reference,
without replaying OAuth. Missing active items and locked/unavailable protection report unavailable,
never disconnected. Linux requires an existing unlocked default Secret Service
collection and the host session D-Bus; this package does not create or unlock it.
macOS uses the user's default Keychain without opening authorization UI. Each
native record read/write suppresses file-based Keychain interaction under a
process-wide lock and restores the preceding policy before releasing it. A
locked item, required approval, or failed policy change reports unavailable.
Unlock or authorize access through macOS, then inspect the original connection
before retrying. The package does not change the Keychain's lock state. This
prevents waiting for an authorization dialog; it does not bound Security daemon
IPC response time.
An existing plaintext `connection.json` is refused, preserved and not migrated;
the operator must reconcile/revoke that old connection before removing its
private plaintext record and starting a new connection.

## Private connection controls

The package advertises the non-exportable `lane_operator` port for `view`,
`connect`, `complete`, transaction-pinned `cancel`, and operation-pinned
`login_approval`, `login_opened`, `login_confirmed` and `login_cancel`.
The host's existing Add-on panel provides its connection form through the [private operator control
contract](../../docs/design/lane-addon-operator-controls.md). Register the exact
HTTPS URL `<your MASC origin>/addons/oauth/callback` with 1Password. The callback
return is sent through authenticated private POST before the fragment is cleared.
The private `callback_receipt` names the original connection and distinguishes
key capture from a durably confirmed decline. Capture does not claim connection
success: an exchange failure can leave a captured key with reconciliation still
required. A lost response permits explicit redelivery of that same original
return; the one-use code exchange is not reexecuted after its durable marker.
For a decline, the protected disconnected record retains the exact receipt and
original state together. Only a validated `access_denied` redelivery with that
same state and connection can recover the receipt; generic views and manual
cancellation do not return it, and a replacement attempt cannot borrow it.
Unconfirmed/busy storage produces no capture acknowledgement. No tokens or PKCE
verifier are returned to the page. Keyless, account-pinned recovery and confirmed
remote revocation remain unfinished; another connection's key is never reused.

These changes are source implementation, not an installed-host or real-account
connection result. The previously installed development package still provides
status only.

## Login lifecycle and remaining docking

`login.py` now implements a private durable lifecycle on the original companion
socket. It pins caller/account/Browser/tab, records intent before requests and
fills, keeps approval links and references in a separate private journal, and
never reconnects or replays an interrupted fill. Explicit next-page fills retain
the same grant for username/password/OTP pages. `finish` releases that grant;
its public result does not certify website authentication. A process lease
prevents another engine from recovering an active owner's operations. Restart
records lost original bindings as unknown rather than adopting a new session.

`service.py` owns a joined background executor for private request/check/fill/release
steps. Public state reads use the last committed snapshot. Cancellation interrupts
the original socket immediately and reports a request receipt; durable cancellation
settlement follows on the owner. Queued fill and release intents are committed
before admission returns. Closing rejects new work, cancels original handles and
joins the worker. Unexpected background errors expose a fixed failure without
printing private tracebacks.

Initial host binding now runs on the same owned worker after admission returns.
The version-3 companion contract retains the successful invocation's original
grant for that bind; unsupported hosts fail negotiation. Status reads and socket
cancellation stay available while the initial bind waits. Worker exports now use
this executor. Only `onepassword_login` receives a new host grant; later calls
use the retained original operation and verify the original caller. The private
UI can reopen the exact approval link. Navigating to the app never starts polling
by itself; a separate human opened acknowledgement starts the vendor clock.
Cancelling a queued login also withdraws its not-yet-bound host nonce through
an independent credentialless control. Only an acknowledged withdrawal permits
a confirmed cancellation; uncertain disposal stays unknown, including on a
repeated close. Closing seals original and withdrawal sockets before another
handle can inherit them.

The approval checker follows the [vendor schedule](https://docs.browserbase.com/integrations/1password/agentic-autofill):
the private link can be retrieved again, and a separate opened acknowledgement
starts the five-second wait. It uses the declared
2/5/10-second windows, pauses for the user after two minutes and respects a
one-minute rate-limit wait. Pausing does not expire the task or create another
request. The service schedules the engine's steps with one checker per request.
Its worker tools and private approval UI are source implementation; private durable delivery into the host Keeper queue is now connected in source.
The isolated native failure-path probe below verifies a subsequent Keeper turn;
real approval, fill and original website-task continuation remain unverified.

The Browser private wire and original-CDP extension loader are now source
implementation. Package-owned `prepare.js` waits for extension readiness and
enables whole-browser agentic mode while the page slot remains held.
`autofill.js` runs request/status/fill, matches grants by entry identity and
rechecks the exact Chrome tab before filling. A fill failure after entry fences
the original session. Their results stay on the private backend path; these
programs are not model tools. The independent host socket broker and two-phase
Python client are [source implementation](../../docs/design/lane-addon-companion-broker.md).
Runtime/private-context authority wiring is also source implementation. The
package negotiates the login-start export through version 3 of the private
companion contract. Original-browser execution and real account verification
remain unfinished.

1. Extend the private connection controls with confirmed remote revocation
   and explicit interrupted-exchange recovery. A new account must not
   borrow an earlier account's integration key.
2. Exercise the login lifecycle through an installed candidate and actual Keeper
   invocation. All seven exports were discovered on an isolated native host;
   its actual Keeper status call does not verify login dispatch or continuation.
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

The host now retains the original Keeper turn/tool-use/task/conversation before
issuing a private companion grant. An existing source binding permits only
reconciliation, not another login dispatch. This is source implementation of
[original invocation capture](../../docs/design/lane-addon-keeper-continuation.md),
not a delivered wake or resumed Keeper turn. The host injects the original
publication callback, and the worker Service delivers through a separate owned
Publisher. Controlled failure delivery has reached a subsequent actual Keeper
turn; successful login and original-task continuation still need runtime proof.

The private login journal now retains typed attention, submitted-fill and terminal
publication intents in the same atomic write as their operation state. A private
ACK records exact-envelope host admission; it is not Keeper consumption. Storage
uncertainty fences the old engine so it cannot overwrite already committed
publication IDs. These private file scenarios are tested with fabricated
credential/Browser edges. Publication transport and Keeper queue admission are
connected to the worker in source. The host has canonical publication retention, a
typed original-source Keeper queue producer and strict observation intake; those
APIs received a real worker terminal publication in the isolated missing-Browser
probe and woke a second actual Keeper turn. Public login replies and observations
contain no outbox or secrets.

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

## Install the development connector

Python 3.11 or later and the installed `masc-native-addon-launcher` are required.
Prepare the package environment in the final installed `onepassword/` directory
before saving its declaration:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

The manifest runs that package's `.venv/bin/python` from its package directory.
Saving a declaration does not create the environment or install dependencies.
The pinned [keyring dependency](https://pypi.org/project/keyring/25.7.0/) supplies
the Python backend; it does not provision or unlock an OS credential store.
The connector uses macOS Keychain or Linux Secret Service. Provision the Linux
service and its session D-Bus through the host OS, outside the declaration.
Protected-record access fails closed when dependencies or the OS backend are
missing, unsupported or locked; public status reports those failures as
`unavailable`. With the package interpreter present, unconfigured MCP
discovery/status does not import `keyring`.

Use the [example declaration](../../docs/examples/lane-addons/onepassword.toml),
resolve `manifest_path` relative to its installed location, and save it under the
runtime's resolved `lane-addons` directory. This package is a normal MCP Add-on;
it does not declare a second `service = "browser"` or replace the Browser owner.
Its skill and tool exports are discovered through ordinary Add-on installation.
Configuration/state failure reports unavailable, never connected.

Preserve the package layout: copy the complete `onepassword/` directory and its
sibling `protocol.py` from the same source commit. The Python worker imports that
shared protocol from its parent directory. Resolve the native launcher from the
matching installed candidate, rather than mixing host generations.

The workspace must already declare its Skill sources in `runtime.toml`, because
this package exports a Skill. Reuse the existing configuration. A minimal
isolated workspace can declare:

```toml
[skills]
[[skills.sources]]
id = "workspace"
anchor = "base-path"
path = ".masc/skills"
access = "read-write"
```

After saving the declaration, inspect its application status and configuration
issues as well as the worker's attached state. An attached worker alone does not
prove its package Skill was admitted.

The operator may provision `connection-config.json` next to `server.py`, owned
by their UID with mode 0600, containing `client_id`, `client_secret_file`,
`redirect_uri` and `store_directory`. For Browser login, add `browser_extension`
with exactly `directory` (the installed unpacked extension absolute path) and
`extension_id` (its 32-character Chrome extension ID). Without that optional
object, account controls remain available and Browser login is unavailable.
Both file/directory paths must be absolute.
The client secret file must be an owned regular 0600 file. The store must be a
dedicated 0700 directory outside Lane retention and agent work disks. Avoid
putting a credential value in the declaration, package skill or config document.
No configuration is required to discover tools and observe `not_configured`.
The worker pins the configuration and client-secret snapshot. A changed or unreadable snapshot
retires that owner and disposes its original grants; restart the Add-on deliberately
after editing settings instead of retargeting live operations. Account-state reads
refuse a busy private lock immediately, so they cannot block subsequent MCP
cancellation behind an extension call.

## Disable or remove the connector

Set `enabled = false` in this connector's installed declaration under the
runtime's resolved `lane-addons` directory and save it. Configuration
reconciliation requests worker cleanup once the declaration and retained-binding
inventory can be read completely; it keeps the declaration. Saving the setting
does not confirm shutdown. Inspect the Add-on's application/lifecycle state and
any cleanup errors.

To remove an attached installation, open the TUI Add-on command input with `A`
and submit `detach <instance-ID>` for the connector's displayed instance ID.
Detach checks the applied declaration and waits for cleanup before removing the
matching TOML declaration. A changed declaration or unconfirmed cleanup is
reported as an error and does not authorize deleting the retained state. See
the [TUI Add-on removal guide](../../docs/guides/tui-lane-addons.md).

Disabling or detaching is separate from confirmed remote 1Password revocation;
it does not erase the operator-owned private connection store.

Protocol references: [partner guide](https://www.1password.dev/agentic-autofill/partners),
[connect](https://www.1password.dev/agentic-autofill/partners/connect),
[extension API](https://www.1password.dev/agentic-autofill/partners/extension-api),
[Browserbase integration](https://docs.browserbase.com/integrations/1password/agentic-autofill).
These are partner preview contracts; confirm access and supported builds with
1Password before using production accounts. The [personal-agent page](https://1password.com/personal-ai-agent-integrations)
includes the feature in Individual and Family plans. The documented developer
registration path requires a separate Business account and production HTTPS
callback; an owner, administrator or Security-group member registers the client.
If OAuth Application is absent, the integration guide directs the developer to
their 1Password contact for activation. A personal end-user account does not
supply that client registration. The documented end-user flow uses a US-region
Individual/Family account on 1password.com.

`delivery.py` owns a separate joined outbox thread. It keeps the original caller
and publisher, acknowledges only exact envelopes after confirmed host admission,
and never blocks the request/check/cancel actor on publication IO. State commits
and existing reads/observations trigger reconciliation after an uncertain ACK.
Storage uncertainty fences publication sockets and cached batches. Shutdown joins
the delivery owner before releasing the engine lease. No endpoint is retained or
adopted after restart. Controlled Service/file/socket tests use a fabricated host
ACK. A separate native probe exercised the actual package, broker, durable queue
and two real Keeper turns with fabricated account state and a nonexistent Browser.
Its terminal `outcome_unknown` was posted through `keeper_surface_post` to the
original Dashboard conversation and retained there. The original Task was null;
this proves the controlled failure continuation, not a real-account login or
restoration of a website Task. See [candidate evidence](../../docs/design/onepassword-addon-docking.md#observed-native-candidate).
