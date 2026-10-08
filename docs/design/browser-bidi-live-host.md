# Attached Firefox BiDi peer

`masc-browser-host --bidi-url ws://127.0.0.1:9222/session` opts into a
Firefox Remote Agent that the operator explicitly enabled. Without this option
the executable continues using WebExtension native messaging stdin/stdout.
The endpoint must be loopback; MASC does not start Firefox, copy a profile,
change preferences, or obtain application tokens.

## Attaching a connection

The operator does both steps. Nothing in MASC starts this Firefox or this host.

1. Start a Firefox with its Remote Agent on a loopback port, on a profile
   kept for this.

   ```sh
   FIREFOX=/Applications/Firefox.app/Contents/MacOS/firefox
   PROFILE="$HOME/masc-keeper-firefox-profile"
   mkdir -p "$PROFILE"
   "$FIREFOX" --no-remote --profile "$PROFILE" --remote-debugging-port 9222
   ```

   `FIREFOX` is the Firefox executable. The path above is the macOS one, the
   only platform this was run on. On Linux it is the `firefox` on the `PATH`.
   `PROFILE` is any directory kept for this. It is not under a hidden
   directory because a Firefox installed as a Snap reaches only non-hidden
   files in the home directory
   ([Snap home interface](https://snapcraft.io/docs/reference/interfaces/home-interface/),
   read 2026-10-08).

   This is a second Firefox beside the one in everyday use, which keeps
   running without the flag. Log in there once, only to the sites a Keeper
   works on. Any local process can connect to that port, drive that browser
   and read its cookies; there is no authentication. The dedicated profile is
   what keeps that to those sites (RFC browser-live-one-connection, decision
   1). The command-line flag is the only way to enable the Remote Agent, so it
   cannot be turned on in a Firefox that is already running.

2. Run the host for the workspace the MASC server serves.

   ```sh
   BASE_PATH="$HOME/masc-workspace"
   "$BASE_PATH/.masc/browser-lane/host/launch" --bidi-url ws://127.0.0.1:9222/session
   ```

   `BASE_PATH` is the directory that holds that workspace's `.masc`; the path
   above is an example.

   The browser lane has to be installed for that workspace first.
   `connectors/browser/install-host.sh` writes the lane token the host and the
   server share (`<base-path>/.masc/browser-lane/token`), a copy of the host
   executable, and the `launch` script used here. The launcher runs that copy
   with this workspace's `--base-path` and token file and passes on what
   follows it, so it does not depend on the `PATH`.

   `masc-browser-host --base-path "$BASE_PATH" --bidi-url ...` is the same
   host when the executable is on the `PATH`. Set `BASE_PATH` before it: an
   empty `--base-path` is taken as the current directory, not as "use the
   default". Leaving the option out uses `MASC_BASE_PATH`.

   The host finds the server's port in the workspace's `connection.toml`. An
   exported `MASC_HTTP_BASE_URL` or `MASC_HTTP_PORT` outranks that file: with
   either set, the host polls that server with this workspace's token. Unset
   both in the shell that runs the host, or name the server with `--server`.

The connection is attached when the TUI's Browser Lane picker (`b`) lists a
`Firefox · BiDi` row, and `/api/v1/dashboard/browser-lane/clients` reports a
client with `transport: "webdriver_bidi"`.

If the everyday Firefox also has the extension connected, the live lane has
two browsers. A request that names no `clientId` is then refused as
`ambiguous_browser_clients`; a Keeper picks the `webdriver_bidi` connection
from the list and keeps its `clientId` for the task.

The host runs in the foreground until it is stopped with Ctrl-C or SIGTERM.
It then finishes and answers a command in flight, tells the server, and ends
the BiDi session it created. A stop that comes while it is still connecting
abandons the attempt. Restarting the MASC server does not end it. A poll the server did not answer is asked again after
five seconds, at the port the workspace's `connection.toml` names once that
port answers, and a result that may not have arrived is sent again before the
next poll. The restarted server sees the same client ID, and Firefox is not
asked for a new session.

It ends by itself in three cases, and says which in its own log output:

- Firefox closed the BiDi connection, or the connection failed. This ends a
  host that is waiting for work too; a command the connection ended under is
  answered first.
- A command's outcome is unknown.
- The server refuses the client's registration. It does so, for one, once it
  has retired that client after two minutes without a poll.

The reason is not reported to the server.

Attaching again is the host command alone. However the host ends, it first
ends the BiDi session it created; Firefox keeps running with its tabs and
takes the next host, which registers as a new client. Without that step the
session would stay in Firefox after the host is gone, and Firefox takes one
session at a time (RFC browser-live-one-connection, section 2.4).

Two cases do leave the session behind. A host started after them is refused
with `session not created` and exits; quit that Firefox, start it with the
same command and profile, then start the host.

- The host was killed with SIGKILL, or crashed.
- Firefox did not answer the session's end within two seconds, or its socket
  was already closed. The host logs `the BiDi session was not ended` with the
  reason. If the socket closed because Firefox quit, there is nothing to
  restart.

Measured on Firefox 157.0.1 on 2026-10-08: a host stopped with SIGTERM was
followed by a second host on the same Firefox, and a host stopped with
SIGKILL was not.

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
Ending the host issues `session.end` and neither browser.close nor
browsingContext.close.

This initial peer does not implement live activate_tab, uploads, download
collection, or the extension's navigation commit barrier. The server refuses
activate_tab on a BiDi connection before it queues a command, by the same
table. page.elements runs the automation lane's element script in the
requested tab, so its selectors are the ones the DOM interactions take. A
page.read with includeHtml runs the automation lane's document helper, which
leaves the HTML out and says why when the result passes 1 MiB. Both reads
answer for the whole document, so a document the parser has not finished is
refused before effect rather than answered with the part that exists.

One socket message carries at most 8 MiB, and a larger one ends the
connection. A page script therefore measures its own answer: one longer than
2,097,152 UTF-16 units is not sent, and the command is refused as
`page_answer_exceeds_bidi_reply_limit` with the size. That is a quarter of
the limit, because a unit takes at most three bytes on the wire and the
envelope needs room. The connection stays up for the next command. The element
script does not bound a control's value or a select's options, so a page can
produce such an inventory. A successful
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
