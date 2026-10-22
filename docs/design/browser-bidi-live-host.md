# Attached Firefox BiDi peer

`masc-browser-host --bidi-url ws://127.0.0.1:9222/session` opts into a
Firefox Remote Agent that the operator explicitly enabled. Without this option
the executable continues using WebExtension native messaging stdin/stdout.
The endpoint must be loopback. The browser Add-on can own a configured Firefox
and its in-process BiDi peer (below). The standalone host is an explicit external
connection; neither mode copies a login profile or obtains application tokens.

## Inspecting unavailable tabs

`tabs.list` retains readable tabs when another context refuses page scripts.
A partial answer has `tabs`, `complete: false`, and `unavailableTabs`. Each
unavailable row keeps its connection-local `id`, `index`, Firefox's error,
and the URL from `browsingContext.getTree` when provided. That URL is an
inventory observation, not proof that its document can be read or controlled.
An unreadable start page does not prevent using an observed ordinary HTTP(S)
tab or opening a fresh one on the same connection. Never replace a user's
existing tab merely to make the listing complete.

## Attaching a connection

### Let the browser Add-on own Firefox

The attached browser Lane Add-on starts Firefox when the live lane is enabled
and the workspace's `runtime.toml` contains:

```toml
[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "/Users/you/masc-keeper-firefox-profile"
# port = 9222
```

`masc browser-lane-setup --mode bidi --base-path DIR` prepares this table and
profile. Explicit `--firefox`, `--profile` and `--port` options replace their
corresponding existing values. Restart MASC to load the configuration, then
attach the browser Add-on or detach and reattach its installation. Log in once
in that Firefox; the dedicated profile preserves its logins.

The Add-on captures this configuration in its original native reservation
before allocating the worker. It acquires a shared profile lease and a child
claim, launches a foreground process owner, and verifies that exact owner's
kernel lease, child birth/group, reported profile and `moz:processID`. A port
already in use is a refusal. An external browser is never adopted as an owned
child. A profile already in use must be closed by its operator before attachment.

The verified peer registers one client UUID directly in the original worker.
Its commands, actors and results stay on that connection. A lost or retired
client is terminal; it is never re-registered under a fresh UUID and browser
input is never replayed. Starting a configured Firefox is part of worker
readiness: startup failure prevents that installation from becoming ready and
joins its other configured backends.

Detaching revokes admission before joining the original peer and browser. An
orderly shutdown sends `browser.close` once and waits for the original owner
and native claim settlement. Failed or cancelled shutdown aborts only that
original owner and retains an unconfirmed result. Profile contents and stable
claim files are preserved. The worker log is `live-firefox.log` in its private
per-incarnation allocation; Add-on observations report readiness or failure.

The server has no independent Firefox startup job. `[browser.live] enabled =
false` leaves this backend unconfigured on the next attachment. Existing
instances retain their captured configuration until detached.

### By hand

Without the table the operator does both steps.

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
   `masc browser-lane-setup --mode host` writes the lane token the host and the
   server share (`<base-path>/.masc/browser-lane/token`), a copy of the host
   executable, and the `launch` script used here, and nothing else. (`--mode bidi`
   writes the same and the table above, so MASC starts the Firefox; `--mode
   extension` writes the same and the extension.) The launcher runs that copy
   with this workspace's `--base-path` and token file and passes on what
   follows it, so it does not depend on the `PATH`.

   Adding `--firefox-profile <profile>` makes the host end a session with a
   Firefox on any other profile, before accepting any page input.

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

The host runs in the foreground until it is stopped with Ctrl-C or SIGTERM,
or its terminal is closed (SIGHUP). It then finishes and answers a command in
flight, tells the server, ends the BiDi session it asked for, and exits 0. A
SIGTERM that arrives after another handled signal has already requested this
graceful shutdown ends it at once, leaving the session in Firefox. A second
Ctrl-C also ends it at once. A stop that comes before the WebSocket is up
abandons the attempt. One that comes while the session request is unanswered
waits for that answer, up to twenty seconds, and then ends the session.

A host started ignoring one of these signals keeps ignoring it. Under
`nohup` it therefore outlives its terminal, and is stopped with SIGTERM.

Exit status 0 says the host stopped as asked and the same Firefox takes the
next one. A host that was stopped and could not end its session exits 1, as
does one that ends by itself. A result the server did not acknowledge is
logged and does not change the status.

Restarting the MASC server does not end it. A poll the server did not answer is asked again after
five seconds, at the port the workspace's `connection.toml` names once that
port answers, and a result that may not have arrived is sent again before the
next poll. The restarted server sees the same client ID, and Firefox is not
asked for a new session.

Sending a result again delivers it only when the first attempt was never
handled. The server takes a result once, so when the first attempt arrived
and only its answer was lost, the second is refused and the host logs that.
A restarted server does not know requests the earlier process issued; a
result for one of those is lost whichever attempt arrives.

It ends by itself in three cases, and says which in its own log output:

- Firefox closed the BiDi connection, or the connection failed. This ends a
  host that is waiting for work too; a command the connection ended under is
  answered first.
- A command's outcome is unknown.
- The server refuses the client's registration for a reason that asking
  again would not change: the request is one it cannot read, it holds the
  client ID as another browser, or it calls a client ID ended on the first
  poll that ID ever sent.

The reason is not reported to the server. It is written to the host's
record, described below.

A server that has ended the host's connection for its silence does not end
the host. The server ends a connection after two minutes without a poll,
which is what a host meets after its machine slept or it was suspended in
the terminal, and it serves that client ID no more. The host then registers
again under a new `clientId` and keeps its BiDi session, so Firefox is not
asked for another. The one case that does end it is the last one above: an
ID that had sent no poll before cannot have fallen silent, and another new
ID would be told the same.
A Keeper that held the old `clientId` reads the list of connections again
and takes the new one; requests under the old one are refused as
`selected_client_disconnected`.

## What the host leaves on disk

The host keeps two files under `<base-path>/.masc/browser-lane/`, so that
whether a host is running, and why the last one ended, can be read without a
server:

- `bidi-host.lock`. The host holds a lock on it from start to exit. The
  kernel drops the lock however the host dies, so nothing has to be kept
  fresh. A workspace has one BiDi host: a second one finds the lock held,
  does not connect to Firefox, names the first one's pid and exits.
- `bidi-host.json`. The host's pid, when it started, the BiDi address
  without its query, the `clientId` it polls as now, and when Firefox gave
  it its session. Every change replaces the whole file.
  - `unacknowledged` lists each result the host holds no acknowledgement
    for: the request's UUID, the verb, and two answers.
    - `outcome`: the command `succeeded`, was refused before any effect
      (`not_started`), or is `unknown`.
    - `cause`: the server answered with a status that refuses the result
      (`refused`), the host never sent it (`not_sent`), or no
      acknowledgement reached the host (`unconfirmed`). The server takes a
      result before it answers, so an `unconfirmed` one may have arrived:
      that is also what an answer the host could not read is, and a result
      that went out once and could not be sent again.
  - After successful archival, the snapshot keeps the newest 64 results.
    Before removing older entries, the host durably appends their complete
    metadata to the private `browser-lane/bidi-host-unacknowledged.jsonl`
    beneath the workspace `.masc` directory. Each schema-1 archive row names
    the host pid, start time and client ID alongside the unchanged result
    fields. This archive is append-only; the ordinary diagnostic log is not
    a durable backup. Archive rows may repeat after uncertain writes.
  - A host that starts appends the previous record's results to the same
    archive, under the previous host's pid, before it writes its own record.
    When that append fails it does not start, and the previous record stays.
  - If archival fails, the host reports the failure and retains every
    unarchived entry in its snapshot, even above the normal window, then
    retries on a later addition. A snapshot write failure retains its state
    in memory for the next write; it does not undo a committed archive.
    The archive and snapshot together carry the metadata; archived entries
    are diagnostic receipts and are never replayed as commands.
  - Readers report the actual snapshot count, including a longer record
    from another writer. Reaching 64 alone does not prove whether older entries exist
    or archival succeeded; the status names the archive without claiming
    that it exists or succeeded from the count alone.
  - A host that leaves in order adds `ended`: when, why,
    `session_in_firefox`, and `because`. A host that could not attach leaves
    its reason the same way. `because` is the cause a next step turns on:
    `profile_not_kept` with `expected`, the profile the host was given with
    `--firefox-profile`, and `found`, the one Firefox said it runs or null
    when it did not say, for a host that ended a session on another profile;
    `reason_only` otherwise. Its paths are written as the reason is.
    - `none`: nothing of this host's is left. Firefox confirmed the end or
      said the connection has no session (`invalid session id`), the host
      never got as far as asking for one, or Firefox answered its request
      for one with an error other than `session not created`.
    - `refused`: Firefox refused the host a session with `session not
      created`. It does that while it holds one: another host's that is
      attached, or one a host that died left there. That session was there
      when this host asked. It stays until its own host ends it or that
      Firefox is restarted, and the record does not say whether it is there
      now.
    - `left`: Firefox was asked and did not confirm: it answered with
      another error, or not in time. It is taken to keep the session, and
      then refuses the next host until it is restarted.
    - `unknown`: the connection was gone before the host could ask. A
      Firefox that quit took the session along; one still running keeps it.

Read together they say one of these:

| Record | Lock | Meaning |
|---|---|---|
| none | free | No BiDi host has run for this workspace. |
| none | held | A host holds the workspace lock before writing its first record; the state is `record_missing_but_locked`. |
| no ending | held | A host is running. It is attached once the record has its session time; a server that is down does not change this. |
| an ending | | The host left in order and said why. |
| no ending | free | The host was killed or crashed, or it left in order and could not write its ending. Its BiDi session may be left in Firefox. |
| unreadable | | The record is not one the reader takes. The reader still says whether a host holds the lock: one that does refuses the next host, which then cannot replace the record. |
| none | cannot be asked | Whether a host started cannot be known. The state is unreadable, with why the lock could not be asked. |
| no ending | cannot be asked | Whether the host runs is not known. The state is unreadable, with why the lock could not be asked. |

A reader looks at the record and then at the lock, so it can be wrong for
as long as one write of the record takes: while a starting host has the
lock and not yet its record, the reader still sees the host before it; and
a host that wrote its ending and exited between the two looks reads as
killed. The next read is right.

A host that starts replaces the record, once the previous record's results
are archived. A previous record it reads and cannot load (another layout, or
damaged) is first copied to `bidi-host.json.unloadable-<pid>-<time>`, named
by the new host; one it cannot read at all is left in place, and that host
does not start. The record carries no lane token, no
request's arguments and nothing read from a page. A request is named only by
the UUID the server issued and by a verb the host knows; for anything else
the field is `null`. A reader built before a verb was added reads that verb
as unnamed and the rest of the record as it is. The reason for ending is the
one free sentence, and it is written as printable ASCII: other bytes appear
as `\xNN`, and a reason longer than 512 bytes is cut.

A reader takes these three only in the form a host writes them: a reason in
printable ASCII, with `\xNN` only for a byte a host does not write as it
is, that is within that length or cut there and marked, an
address as a host records it, and a client ID the lane would take. Anything
else makes the record unreadable to it. What a reader passes on to an
operator, a terminal and a model is then one line of known bytes and length;
what the line says is not judged. Times are written to the nearest
millisecond, and one a host wrote is written back as the same text.

The host does not start when it cannot take the lock or write its first
record: a host that held the lock under its predecessor's record would be
read as that predecessor. A record that could not be written later does not
stop a serving host; the next write that succeeds carries it.

Four places read the record and say what it says, with what the operator
does next:

- `masc doctor` prints a `browser_bidi_host` line. It reads the files, so it
  answers with no server running. The dashboard's setup check
  (`GET /api/v1/setup/status`) is the same check inside a server.
  - `satisfied`: a host runs and the server that answers lists its client.
    That is where hover and drag are served.
  - `needs_verification`: a host runs and that is all that is known. It is
    still connecting, the check runs outside a server as `masc doctor` does,
    or the answering server does not list the host's client.
  - `needs_setup`: none runs.
  - `invalid`: the record or its lock cannot be read.

  A workspace with no browser lane installed and no record has no such line.
- `GET /api/v1/dashboard/browser-lane/clients` adds `bidiHost` beside
  `clients`:
  - `state`: `never_started`, `record_missing_but_locked`, `running`, `ended`, `died` or `unreadable`.
  - What the state was read from: the `record`, whether the host's lock was
    held as `lock_held`, and why either cannot be read as `detail`. A reader
    works the state out again from these and refuses a report whose `state`
    is another.
  - `attach`: the host command as `launcher` and `arguments`, and
    `launcher_state` (`installed`, `not_installed`, `needs_reinstall`).
  - `keeper`: the configured browser ownership, by `kind`.
    `addon_managed` carries the configured `port` and `profile`. The attached
    Add-on observation supplies actual worker and connection readiness.
    `lane_off`, `not_configured` (no `[browser.live.bidi]`) and `not_known`
    (no configuration was read) carry nothing more.
  - `message`: the paragraph the doctor prints.
- A Keeper whose hover or drag is refused as `live_transport_unsupported`
  while no connected browser serves it gets `bidiHost` in the answer, with
  `state` and `message` only, to pass on to the operator. An answer that
  offers a connection in `servingClients` has no `bidiHost`.
- The TUI's Browser Lane picker draws it from the server's `bidiHost`:
  whether a host runs and whether the server lists it, why the last one
  ended, what comes before the next, the results the host holds no
  acknowledgement for, and the command that starts one, or, where MASC
  starts it, that MASC does and what its last start left
  ([the rows](../guides/tui-browser-lanes.md)).

The doctor, the connection list and the Keeper's answer each read the
record first and ask the server for its connections once, after that. What
an answer says of the host and the connections it lists are of that one
list. The TUI draws what the connection list answered.

The paragraph says what comes before the next host. That follows what became
of the last one's session. Once a host has run, the host command in the
paragraph names the address that host was given, and the Firefox flag names
that address's port:

| The last host | Before the next one |
|---|---|
| ended, session `none`, after it was attached | Nothing: the host command, while that Firefox still runs. |
| ended, session `none`, before Firefox gave it a session | Check that a Firefox answers at that address, then the host command. |
| ended, session `left` | Restart the Firefox at that address. |
| ended, session `unknown` | Start that Firefox again, restarting it if it still runs. |
| ended, session `refused` | Stop a host still attached to that Firefox, then the host command. When that host is refused too with none attached, restart that Firefox first. |
| died | Run the host. When Firefox refuses it a session, restart that Firefox and run it again. |

When the workspace has no launcher, or one that is not as an installation
wrote it, the paragraph says to install the lane first. A paragraph of a
running host, and of a record that cannot be read while a host holds the
lock, names no command: there is none to run.

A path and an address in a command are written as one shell word each, in
single quotes. The reason for ending is the host's own words: it is set in
double quotes, and a double quote in it is written `\"`.

A host can run and be attached while the answering server does not list its
client:

- The server lists no BiDi connection. Hover and drag are refused on that
  server, and the paragraph names what makes the two differ: the host polls
  another server (an exported `MASC_HTTP_BASE_URL` or `MASC_HTTP_PORT` in
  its shell), it has not polled for 120 seconds and the server ended its
  connection, or the server started moments ago.
- The server lists another BiDi connection. That connection is this host's
  when it registered again under a new ID that it could not write to its
  record; otherwise it is another host's. The paragraph says both and does
  not say that hover and drag are refused.

The record can also say that no host runs while the server lists a BiDi
connection: a host that died stays listed until 120 seconds pass without a
poll, and a host started for another workspace can poll this server. The
paragraph says so beside what the record says.

Attaching again is the host command alone. A host that is stopped, or ends
by itself, first ends the BiDi session it asked for; Firefox keeps running
with its tabs and takes the next host, which registers as a new client. Without that step the
session would stay in Firefox after the host is gone, and Firefox takes one
session at a time (RFC browser-live-one-connection, section 2.4).

These do leave the session behind. A host started after them is refused
with `session not created` and exits; quit that Firefox, start it with the
same command and profile, then start the host.

- The host was killed with SIGKILL, a second Ctrl-C, or a SIGTERM after graceful shutdown had already been requested, or crashed.
- Firefox did not answer the session's end within two seconds, or its socket
  was already closed. The host logs `the BiDi session was not ended` with the
  reason. If the socket closed because Firefox quit, there is nothing to
  restart.

A host refused with `session not created` asked for a session and got none,
so it leaves none: stopping it changes nothing in Firefox.

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
BiDi and WebDriver share the native pointer action encoder. A drag moves to its
destination twice before releasing, so dragover handlers can observe it where
the browser supports HTML drag-and-drop. An accepted gesture receipt proves
the input sequence, not an application drop. Firefox's native HTML draggable
drop is affected by [Mozilla bug 1515879](https://bugzilla.mozilla.org/show_bug.cgi?id=1515879);
pointer-capture drags are a separate supported interaction. MASC does not replay
the gesture with synthetic DOM events when a drop is absent.
Pointer receipts read only the URL, title and scroll position. Screenshot
validation also reads tab metadata instead of the document body, so a large
page does not turn completed input or capture into a body-size failure.
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
the resolved tab with `tabId`. Stagehand Chromium also serves `hover_at`, semantic
`hover`, and semantic `drag_to` with the same observed-target resolution and
URL/viewport checks. It sends the runtime's native `page.hover` or
`page.drag_and_drop` calls, without a model or synthetic DOM input. Observed
selector and scene-node clicks resolve into native `page.click` with the
resolver's current URL and viewport guarded before input. Custom drag
paths are forwarded as CSS-pixel runtime routes. An omitted path visits the
midpoint before the destination, so pointer-capture handlers can activate
before the destination move. For semantic `drag_to`, the resolver can provide
an additional arrival point inside the observed destination rectangle. It is
distinct from the destination center and independently hit-tested against the
same element. Stagehand visits that point after the requested path and before
the center, allowing native dragenter followed by dragover before release.
An occluded or pixel-sized destination supplies no invented arrival point.
Raw coordinate drags carry only their requested/default path; an input receipt
does not establish HTML drop acceptance. Nonzero `durationMs` is refused before input:
the runtime pause after a move does not express movement duration.
This is not an atomic snapshot/input
transaction: the operator can still change the page after validation. There is
no write replay. An unknown outcome stops this live client. Reads and interactions
share the existing host command deadline; connection setup has that same bound.
Protected pointer-release cleanup can additionally run up to one transport
deadline after the outer command deadline. A timeout is not an instantaneous
release guarantee.
Screenshot guards read URL, title and document/viewport identity together before
and after capture, without reading or serializing the document's text. A text
read that is slow or too large is therefore not a prerequisite for a screenshot.
The element inventory shares computed styles and ancestor display/opacity checks
within one synchronous observation; later observations recompute them.
Pointer receipts use the shared URL/title/scroll observation, also without a
whole-document text read after input.
Ending the host issues `session.end` and neither browser.close nor
browsingContext.close.

A tab whose metadata cannot be read is retained in `unavailableTabs` alongside
`complete: false`; readable tabs keep their IDs. This partial listing does not
prevent an explicit read or capture of a readable tab. Implicit active-tab
selection also continues past unreadable tabs using metadata only, and includes
their refusal details when no readable active tab is found. Closing an unreadable
tab is not required to use another tab.

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
trusted pointer-capture drag, stale viewport rejection, large-document pointer
receipts, and two identical-URL contexts.
The latter requires the CI-built host and Firefox; no local build is needed.

Protocol references: [Mozilla direct connection](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection),
[BiDi input](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/input/performActions),
[Remote Agent security](https://firefox-source-docs.mozilla.org/remote/Security.html).

## Agent feedback and pointer observation

BiDi interactions display a non-interactive MASC badge with the authenticated
Keeper/calling-agent label and operation. While the page channel remains available it settles to Finished, Not performed,
or Outcome unknown when the host completes or unwinds the request. A lost
transport cannot update an existing badge; inspect the connection before treating
a retained Working badge as current. Navigation does not create a new badge for
an old request's cleanup. A page refusing
feedback does not authorize a replay or prevent the interaction.

Stagehand Chromium also displays this feedback for an explicitly attributed
Keeper interaction. The selected actor stays on the backend's queued request
and owns the serialized guard/input/receipt operation. Each interaction gets
its own request identity; cancellation-protected cleanup settles that same
badge without changing the authoritative result. Anonymous direct calls do
not invent an agent identity. Semantic click, hover and drag receipts preserve
their originally requested action name.

The marker follows trusted browser pointer/wheel/drag events and displays CSS
viewport coordinates. Before any event its position is unknown; this is the browser
input pointer, not the desktop mouse cursor. The inert shadow overlay receives no
pointer input and does not add its text to the page read surface. A later command
cannot be marked finished by cleanup belonging to an earlier request.

Connection discovery reports queued/running interactions and their actors from
the server's owned queue. The TUI labels these as the last connection observation;
refresh the connection list to inspect a newer observation. It does not infer a
remote agent's state from the local TUI loading indicator.

Firefox internal start pages (`about:newtab`, `about:home`) can appear in the
context tree while rejecting `script.callFunction` with `unsupported operation`.
An inventory with only these pages has no readable tabs and reports them in
`unavailableTabs`. Open a normal site in the dedicated Keeper Firefox profile and
read the connection again. MASC does not expand Firefox system-page permissions.
BiDi errors retain the rejected command name; fixed-script exceptions retain the
browser's reason, including stale-document/viewport refusals.

## Open a tab on the selected BiDi connection

Use `masc_browser_act` with `action:"open_tab"`, `lane:"live"`, the exact
observed `clientId`, and an absolute HTTP(S) `url`. Live `page.act` serves only
this action; other automation actions remain outside its capability. The
WebExtension connection does not serve new-tab creation.

The host creates a background tab in the selected Firefox profile, navigates
only that new context, and returns `tabId`, `created:true`, `url`, and `title`
with the server's connection identity. Use this returned tab ID and client ID
for page reads and hover; new tabs share that profile's default user context.
Existing tabs and protected start pages are left in place. This is an explicit
request, never an automatic response to a failed start-page read.

A refused creation or a command never written is a pre-effect failure. When
creation is confirmed but navigation is refused or the page summary fails,
the response remains a failure with `effectPhase:"partial"` and a structured
`created:true`/`tabId` receipt. The server adds the selected connection identity
and keeps that receipt in the Keeper's error output. The host keeps serving
this connection, so the caller can list or read the same tab before deciding
what to do next. This is a confirmed effect, never permission to replay creation.

A lost reply or broken session remains an unknown outcome and ends the
connection. The host never creates another tab or closes the created context
to recover. List current connections and observe their tabs again; old
connection tab IDs must not be reused on a replacement connection.

### Trusted semantic clicks

On BiDi and automation, `click` with one observed selector or scene
`documentId`/`nodeId` resolves a visible, unobstructed target and sends native
pointer move/down/up. This supports menus that open on trusted `pointerdown`
or `mousedown`, including a control exposed by hover. Re-observe the revealed
controls before selecting one. Disabled controls, inherited `aria-disabled`,
ambiguous selectors and stale scene references are refused before input.
Labels retain their associated-control semantics, including visible text in a
`display:contents` label. Targets outside the viewport require scrolling and a
fresh observation first.

`expectedUrl` remains optional for semantic click. If omitted, resolution
captures the current URL and the native input guard checks that URL and the
resolved viewport before dispatch. There is no DOM-click fallback or automatic
replay after native input. The WebExtension's DOM-click behavior is unchanged.

### Drag movement and acceptance

`drag` and `drag_to` accept `via` (ordered normalized viewport points) and
`durationMs` (milliseconds for each move). Without a path, native BiDi and
WebDriver visit the midpoint before the destination so controls that activate
on initial movement receive another changed position before release. Custom
paths must come from the observed viewport; stale geometry fails before input.
Stagehand forwards custom paths through its native route option. Nonzero movement
timing is refused before input because the runtime's delay is a pause after a
move rather than the duration of that movement.
A successful native input receipt proves dispatch and release, not that a page
accepted a drop. Re-read the application result before reporting success or
retrying. HTML5 `draggable`/`DataTransfer` requires separate verification from
pointer-capture dragging; Firefox's upstream issue is
[Bug 1515879](https://bugzilla.mozilla.org/show_bug.cgi?id=1515879).

### Observing hover controls

After hover, read the page again before selecting the newly visible control.
Scene output uses the requested `maxChars` text budget and its existing 1 MiB
response limit. Visible controls later in DOM order are not silently excluded
by a separate 200-node quota. Nodes are admitted against the complete JSON's
UTF-8 byte size, including their geometry and metadata. When the next node
would exceed the byte ceiling, the result keeps the admitted nodes and full
page identity with `truncated:true`. An identity envelope that cannot fit by
itself is refused rather than shortened. Check `truncated` and use an observed
region scope or the element inventory when a text or byte budget is exhausted.
A missing control in a truncated observation is not evidence that hover failed.

### Native double clicks, text, and key chords

`masc_browser_interact` supports `double_click` on an observed selector or scene
node, and `double_click_at` on a captured viewport point. Stagehand sends native
`page.click` with `click_count: 2`; WebDriver and BiDi send two native button
press/release pairs in one owned input sequence. These actions use the same
visibility, disabled-control, document, viewport, and URL guards as native click.

`click_at` takes an optional `button`: `primary` (the default), `middle` or
`secondary`. WebDriver and BiDi press and release the matching pointer button
(0, 1 or 2) at the observed point. Stagehand sends `page.click` with
`options.button` set to `middle` or `right`; the pinned 4.1.0 runtime accepts
those values, but no real-Chromium run of it has been recorded. The
WebExtension clicks through the DOM and refuses a non-primary button before any
input is sent. A
`secondary` click opens whatever the page binds to the context menu; observe the
page afterwards, the receipt does not say what it did.

Each `tabs.list` row carries `windowId` when Firefox's `browsingContext.getTree`
names the tab's `clientWindow` (Firefox 158 does, probed 2026-10-22). Tabs with the
same `windowId` share a window, and the distinct values are the windows. The number
is assigned by this connection in the order it first sees a window, so it is not
comparable across connections. There is no window title, size or position, and no
way to create or close a window yet.

`tap_at` and `swipe` send the same WebDriver pointer sequences as `click_at`
and `drag`, from a pointer whose `pointerType` is `touch`. Firefox 158 reported
`pointerdown`, `touchstart`, `pointerup` and `touchend` to the page for a tap,
each trusted, followed by the mouse events and a click (probed 2026-10-22), and
`pointermove` events through a swipe. Stagehand has no touch call and the
WebExtension clicks through the DOM, so both refuse before any effect.

`back`, `forward`, `reload` and `close_tab` act on a top-level tab only if this
connection opened it with `open_tab`. A tab the operator opened is refused before
any browser call: it holds pages and unsaved state this host never saw, and these
actions carry no `expectedUrl` that says which page the caller observed. The
commands are `browsingContext.traverseHistory` (delta -1 or 1),
`browsingContext.reload` (waiting for the document) and `browsingContext.close`
with `promptUnload: false`. Firefox's error codes `no such history entry`,
`invalid argument` and `no such frame` mean nothing happened. Any other error is
a result that is not known: a reload or a history step that lands on an error
page is answered with an error after the tab moved.

`set_viewport` resizes the tab's page viewport, not the browser window. A live
BiDi connection sends `browsingContext.setViewport` with the size, or with
`viewport: null` when no size is given, which gives the browser's own size back.
Firefox 158 reports the new `innerWidth` and `innerHeight` right after the
command (probed 2026-10-22), and it accepts widths of 0 and 100000 without an
error, so the lane bounds each side to 100 to 4096 CSS pixels itself. The
override stays on the tab until it is cleared. Firefox 158 keeps it after the session ends (probed 2026-10-22: a new session read the old size), so the peer gives each tab it sized its own size back when it ends the session. A host that dies without ending its session leaves the size on the tab. Stagehand sends
`page.set_viewport_size` and has no call that restores the size; the owned
Firefox driver and the WebExtension refuse the action before any effect.

`type_text` sends Unicode text into the currently focused editable control.
`press_key` sends one named key or Unicode scalar, optionally with explicit
`Control`, `Meta`, `Alt`, and `Shift` modifiers. Both require the observed
`documentId` and `expectedUrl`; a reload of the same URL fails the document guard.
Typing additionally requires enabled editable focus. Control characters are
refused as text: use an explicit `press_key` for Enter or Tab so a text request
cannot silently change focus or submit a form. The guard never focuses a
control or dispatches events: first use an observed native click to focus it.
Use `Meta` with `a` for select-all on macOS and `Control` with `a` where appropriate.

Stagehand uses its real `page.type` and `page.key_press` methods. WebDriver and
BiDi use native key down/up input sources and release all held input even after
cancellation or an unanswered dispatch. Unicode scalars stay intact. W3C's
reserved special-key scalars U+E000 through U+E05D are refused as text instead of
becoming commands. An unanswered input remains uncertain and is never replayed.
Stagehand refuses supplementary Unicode scalars in `press_key` before input;
use `type_text` for such text. If native Stagehand keyboard input may have
started without confirmed key release, the backend quarantines that exact owned
session without closing its pages. Status remains available; explicitly close
and reopen before further work. Input is never replayed for cleanup.
Receipts report the original action and page identity without echoing typed text.

WebExtension does not serve these native actions. Actual browser zoom is a
separate WebExtension-only action described below.
`test/fixtures/browser-native-input.html` records trusted double-click and keyboard
input for isolated native browser probes. Source tests and protocol fixtures do
not establish that an installed browser has completed these interactions.


### Actual browser zoom

`masc_browser_interact` action `set_zoom` requires the observed WebExtension
`clientId`, `tabId`, `expectedUrl`, and an explicit numeric `factor` from 0.3
through 5. The extension must be version 0.8.0 or later. BiDi, owned WebDriver
and Stagehand refuse this action before input; the server does not switch
browsers to perform it.

The extension reads the tab URL, current zoom, and zoom settings, checks the URL
again immediately before one `tabs.setZoom` call, then reads the resulting zoom
and URL. The receipt reports `requestedFactor`, measured `zoomBefore` and
`zoomFactor`, plus actual `zoomScope` and `zoomMode`. Manual or disabled zoom
modes are refused because this action requires the browser to apply the zoom.
It never changes zoom settings or uses CSS zoom or viewport resizing.

Firefox normally uses automatic, per-origin zoom. Thus the explicit tab selects
the origin being changed, but the change can affect other same-origin tabs and
persist for the site. The receipt retains this scope instead of promising a
per-tab effect. See [MDN setZoom](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/setZoom),
[zoom settings](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs/getZoomSettings),
and [Firefox zoom behavior](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Working_with_the_Tabs_API).

After zoom, obtain a fresh scene or screenshot before using viewport geometry.
A failure after dispatch, including failed measurement or navigation during the
command, leaves an unknown outcome and is never automatically replayed. The
API's zero-to-reset shorthand is deliberately excluded: callers supply an
explicit factor. [Isolated native evidence](../evidence/2026-10-19-browser-zoom/README.md)
records actual 150% and 75% browser zoom and the exact execution boundary.

### Owned Chrome tab and history actions

On `lane=stagehand`, BrowserAct serves `open_tab` and top-level `back`,
`forward`, `reload`, and `close_tab` using the runtime's native
`context.new_page`, `page.go_back`, `page.go_forward`, `page.reload`, and
`page.close` methods. These actions do not call a model or simulate navigation
through page JavaScript. Retain the observed lane and tab ID for all subsequent
work. Frame actions, dialogs, uploads, and other BrowserAct actions remain
unsupported on this lane and fail before dispatch.

Creation and initial navigation are separate calls. If the new page is known
but navigation or metadata fails, the failed answer carries `effectPhase:
partial` and a receipt with `created:true`, the created `tabId`, and owning
`lane:stagehand`. A runtime navigation success that exposes a browser error page
instead of an HTTP(S) page is also partial. The same receipt reaches the tool's
failed data and model-facing output. Inspect the same owned browser before
choosing recovery; the executor never creates a replacement automatically.
An unanswered creation has unknown effect and never invents a tab ID.

A close retires its tab ID only after native `closed:true` confirmation.
Malformed close replies retain the identity with uncertain outcome, without
replaying close. IDs increase across closing and reopening pages and across
owned sessions, so an old tab ID cannot select a newly created page.
