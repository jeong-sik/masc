# 1Password connector (Experimental)

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
URL must never enter a tool result, Ask text, observation, log or model context.
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
macOS uses the user's default Keychain; OS authorization UI may be required.
The package never answers that UI or changes the Keychain's lock state.
An existing plaintext `connection.json` is refused, preserved and not migrated;
the operator must reconcile/revoke that old connection before removing its
private plaintext record and starting a new connection.

## Docking contract still to implement

1. An authenticated operator surface for connect, callback, approval links,
   revocation and explicit interrupted-exchange recovery. A new account must not
   borrow an earlier account's integration key.
2. Complete the status-only package's login tools and operator UI integration
   through existing Lane Add-on discovery and host-context caller identity.
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

## Install the development status connector

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
Its skill and `onepassword_status` export are discovered through ordinary Add-on
installation. Configuration/state failure reports unavailable, never connected.

The operator may provision `connection-config.json` next to `server.py`, owned
by their UID with mode 0600, containing exactly `client_id`, `client_secret_file`,
`redirect_uri` and `store_directory`. Both file/directory paths must be absolute.
The client secret file must be an owned regular 0600 file. The store must be a
dedicated 0700 directory outside Lane retention and agent work disks. Avoid
putting a credential value in the declaration, package skill or config document.
No configuration is required to discover the tool and observe `not_configured`.

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
1Password before using production accounts. Client registration currently needs
a Business account and a production HTTPS callback; end-user consent uses a
separate Individual/Family account on 1password.com.
