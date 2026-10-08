# Attached Firefox BiDi peer

`masc-browser-host --bidi-url ws://127.0.0.1:9222/session` opts into a
Firefox Remote Agent that the operator explicitly enabled. Without this option
the executable continues using WebExtension native messaging stdin/stdout.
The endpoint must be loopback; MASC does not start Firefox, copy a profile,
change preferences, or obtain application tokens.

## Attaching a connection

The operator does both steps. Nothing in MASC starts this Firefox or this host.

1. Start Firefox with its Remote Agent on a loopback port.

   ```sh
   /Applications/Firefox.app/Contents/MacOS/firefox --remote-debugging-port 9222
   ```

   The command-line flag is the only way to enable the Remote Agent, so a
   Firefox that is already running without it has to be quit first. Any local
   process can connect to that port, drive the browser and read its cookies;
   there is no authentication. A profile that is logged in only where a Keeper
   works (`--profile <directory>`) limits what the port exposes to those
   sites, at the cost of logging in there once.

2. Run the host for the workspace the MASC server serves.

   ```sh
   masc-browser-host --base-path "$BASE_PATH" --bidi-url ws://127.0.0.1:9222/session
   ```

   The browser lane has to be installed for that workspace first:
   `connectors/browser/install-host.sh` writes the lane token the host and the
   server share (`<base-path>/.masc/browser-lane/token`). The host finds the
   server's port in the workspace's `connection.toml`; `--server` names one
   explicitly.

The connection is attached when the TUI's Browser Lane picker (`b`) lists a
`Firefox · BiDi` row, and `/api/v1/dashboard/browser-lane/clients` reports a
client with `transport: "webdriver_bidi"`.

The host runs in the foreground until it is stopped. It also ends by itself
when a command's outcome is unknown, or when a poll or a result does not reach
the server, so restarting the MASC server ends it. It does not retry; start it
again. The reason goes to the host's own log output and is not reported to
the server.

The peer attaches only to a browser that reports itself as `firefox`. Zen has
not been tried.

The BiDi connection owns its opaque context to integer tab mapping. IDs are not
recycled during the client lifetime and are never joined to extension IDs or
URLs. Tab visibility and Firefox version are observed, not inferred from index.
Unsupported verbs fail explicitly. Fixed repository scripts provide DOM reads,
scenes, document references, and semantic interactions; command arguments are
JSON data, never supplied JavaScript.

Screenshot coordinate input uses the existing document/viewport guard followed
by BiDi pointer or wheel actions. `hover_at` uses one `pointerMove`, with no
button press, on the selected live BiDi tab or the automation lane. Copy the
observed `expectedUrl`, `viewport` and normalized `point` from a fresh capture.
The server refuses `hover_at` and `drag` on a WebExtension connection before
it queues a command, as `live_transport_unsupported`; the operator must
explicitly attach the already-enabled loopback Remote Agent with `--bidi-url`.
[What each live connection serves](browser-lane.md#what-each-live-connection-serves)
is the whole table. Live-client
discovery reports `transport: "web_extension"` or `"webdriver_bidi"` alongside
each `clientId`, including the ambiguity response and
`/api/v1/dashboard/browser-lane/clients`. Select the `webdriver_bidi` client,
read that client's tabs, and capture again; extension tab IDs are not converted
to BiDi tab IDs. The host declares its mode with `x-browser-transport`. An
installed host that omits this header uses the WebExtension poll contract;
BiDi hosts declare `webdriver_bidi`. The server rejects empty or unknown values
and a transport change on an existing client ID. Interaction receipts identify
the resolved tab with `tabId`. Stagehand rejects trusted hover before input. This is not an atomic snapshot/input
transaction: the operator can still change the page after validation. There is
no write replay. An unknown outcome stops this live client. Reads and interactions
share the existing host command deadline; connection setup has that same bound.
Protected pointer-release cleanup can additionally run up to one transport
deadline after the outer command deadline. A timeout is not an instantaneous
release guarantee.
Closing the socket does not issue browser.close or browsingContext.close.

This initial peer does not implement live activate_tab, uploads, download
collection, or the extension's navigation commit barrier. The server refuses
activate_tab on a BiDi connection before it queues a command, by the same
table. page.elements runs the automation lane's element script in the
requested tab, so its selectors are the ones the DOM interactions take. A
page.read with includeHtml runs the automation lane's document helper, which
leaves the HTML out and says why when the result passes 1 MiB. A document the
parser has not finished is refused before effect rather than returned as
complete. A successful
follow receipt does not guarantee application content is ready; existing guarded
read recovery remains necessary. A BiDi session enables browser-wide automation
and must not be exposed beyond loopback.

Validation: `test_browser_bidi_peer` exercises opaque identity, the element
inventory, the document source and the lane table against the peer.
`python3 test/test_browser_bidi_host.py HOST FIREFOX` uses an owned temporary
profile and actual Firefox to exercise native HTTP poll/result, screenshot,
trusted drag, stale viewport rejection, and two identical-URL contexts.
The latter requires the CI-built host and Firefox; no local build is needed.

Protocol references: [Mozilla direct connection](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection),
[BiDi input](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/input/performActions),
[Remote Agent security](https://firefox-source-docs.mozilla.org/remote/Security.html).
