# 1Password connector (Experimental)

Backend connection foundation for [#45736](https://github.com/jeong-sik/masc/issues/45736).
The package connects the operator's 1Password account through private operator
controls and exports one model-safe tool, `onepassword_status`, which reads
whether that account is connected. No real-account connection has been verified.

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

`oauth.py` also keeps the backend callbacks `connection_identity()`,
`credentials(use, expected_connection_id=...)` and `disconnect(revoke)`. No package
code calls them. `credentials` holds the connection lock through its callback,
serializes rotating refreshes and fences an interrupted exchange or refresh.
`disconnect` confirms remote revocation before it reports the connection
disconnected. A lost exchange response requires remote reconciliation rather
than blind replay.

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
`connect`, `complete` and transaction-pinned `cancel`.
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

These controls are source implementation, not an installed-host or real-account
connection result.

## Verification

Run `python3 -m unittest discover -s addons/tests -p 'test_onepassword_*.py'`.
The checks use transport fixtures and actual MCP subprocesses, never a personal
account or real tokens. The private callback checks also verify that public
status/observations contain none of the fixture OAuth material.

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
runtime's resolved `lane-addons` directory. This package is a normal MCP Add-on.
Its tool export is discovered through ordinary Add-on installation.
Configuration/state failure reports unavailable, never connected.

Preserve the package layout: copy the complete `onepassword/` directory and its
sibling `protocol.py` from the same source commit. The Python worker imports that
shared protocol from its parent directory. Resolve the native launcher from the
matching installed candidate, rather than mixing host generations.

The operator may provision `connection-config.json` next to `server.py`, owned
by their UID with mode 0600, containing `client_id`, `client_secret_file`,
`redirect_uri` and `store_directory`, and no other key. Both file/directory paths
must be absolute.
The client secret file must be an owned regular 0600 file. The store must be a
dedicated 0700 directory outside Lane retention and agent work disks. Avoid
putting a credential value in the declaration or config document.
No configuration is required to discover tools and observe `not_configured`.
The worker pins the configuration and client-secret snapshot. A changed or unreadable
snapshot retires that worker's connector, and status then reports `unavailable`.
Restart the Add-on deliberately after editing settings. Account-state reads
refuse a busy private lock immediately instead of waiting for it.

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
[connect](https://www.1password.dev/agentic-autofill/partners/connect).
These are partner preview contracts; confirm access and supported builds with
1Password before using production accounts. The [personal-agent page](https://1password.com/personal-ai-agent-integrations)
includes the feature in Individual and Family plans. The documented developer
registration path requires a separate Business account and production HTTPS
callback; an owner, administrator or Security-group member registers the client.
If OAuth Application is absent, the integration guide directs the developer to
their 1Password contact for activation. A personal end-user account does not
supply that client registration. The documented end-user flow uses a US-region
Individual/Family account on 1password.com.
