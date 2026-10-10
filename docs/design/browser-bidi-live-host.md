# Attached Firefox BiDi peer

`masc-browser-host --bidi-url ws://127.0.0.1:9222/session` opts into a
Firefox Remote Agent that the operator explicitly enabled. Without this option
the executable continues using WebExtension native messaging stdin/stdout.
The endpoint must be loopback. MASC starts that Firefox only for a workspace
whose `runtime.toml` names it (below); it does not copy a profile, change
preferences, or obtain application tokens.

## Attaching a connection

### Let the MASC server start both

With this table in the workspace's `runtime.toml`, the MASC server starts the
Firefox and the host when it starts (RFC-browser-keeper-firefox):

```toml
[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "/Users/you/masc-keeper-firefox-profile"
# port = 9222
```

- It starts only what is missing. A port that already answers gets no second
  Firefox, and a host holding the host lock gets no second host.
- It starts Firefox only together with a host. It starts neither when the
  browser lane is not installed, or not as its installation wrote it; when
  the host holding the lock was given another port, or its record cannot be
  read to say which; or when that host is on this port, since a host
  attaches to Firefox once, when it starts. A workspace has one host, so
  such a host is stopped first; one whose Firefox is gone ends by itself,
  and the next server start opens both. Firefox's port lets any local
  process drive it, so it is not opened for nothing.
- A Firefox the server started and left with no host is stopped through its
  process group: one whose port did not open within the 30 seconds, and one
  whose host could not be started. It gets SIGTERM, then SIGKILL after 5
  seconds. A Firefox whose port answered before the server looked is never
  touched.
- A host that leaves in order writes its ending before it gives up the
  lock. A server that starts in between waits up to 5 seconds for the lock,
  so the host it starts is not refused; a lock still held then starts
  nothing.
- Both run apart from the server, so a server restart leaves them running.
  Firefox writes to `.masc/browser-lane/keeper-firefox.log` and the host to
  `.masc/browser-lane/bidi-host.log`. Each start moves the last run's log to
  `<name>.1`, over the one before; within one run a log keeps growing, by a
  line every five seconds from a host whose server is away. The server log
  says what it started and why it did not.
- The host is started with the workspace's installed `launch`, so the browser
  lane is installed first (step 2 below). It is not given the server's
  `MASC_HTTP_BASE_URL` or `MASC_HTTP_PORT`, which would fix its server
  address over `connection.toml`.
- The host is also given the profile (`--firefox-profile`). Firefox reports
  the profile it runs with the session (`moz:profile`; Firefox 157.0.1 gives
  the path as it was given, so both paths are resolved first). A host whose
  Firefox runs another profile ends that session and stops, and its record
  says which profile it found. So a port that answers because the everyday
  Firefox was started with `--remote-debugging-port` does not give a Keeper
  that profile; it gets a session that is ended at once.
- The server records the Firefox it starts in
  `.masc/browser-lane/keeper-firefox.json` right away, before waiting for
  its port: its process group, when its first process started, the profile
  and the port. A Firefox it cannot record is stopped, and no host is
  started for it. The record is removed when that Firefox is stopped or
  ends before its port answers. A server starts no Firefox over a record
  whose group may still run, or over a record it cannot read: a server
  that ended while its Firefox was opening the port leaves one, and a
  second Firefox on the same profile would end at once and take that
  record with it.
- While the server runs, a Keeper's hover or drag that no listed connection
  serves has the server start what is missing the same way, one start at a
  time, and wait up to 15 seconds for the BiDi connection. The request
  itself is not sent there; the answer names the connection and what was
  started (`bidiConnection`) and asks the Keeper to list its tabs and
  observe again, or says why none was shown and what a retry does
  (`bidiStartFailed`: `operator_needed`, `start_failed`,
  `not_listed_in_time`). Reads, clicks and scrolls start nothing. A host
  that ends before its connection is listed has the Firefox started for it
  stopped, at a server start as at a request.
- `[browser.live] enabled = false`, or a `runtime.toml` without the table,
  starts nothing, and stops the Firefox that record names when it is shown
  to be the one MASC started: the process its group is numbered after still
  runs, started when the recorded one started, in that group. Anything else
  is left running and the server log says why; the operator closes it. The
  host ends with its Firefox. A server that could not load `runtime.toml`
  stops nothing. Before each signal the server checks again that the
  number still names that group, and a group whose processes it may not
  signal is never taken for gone.
- The operator still logs in once, in that Firefox, to the sites a Keeper
  works on; the profile keeps the login.
- A Firefox that exits before its port answers, leaving nothing in its process
  group, is reported as such: Firefox 157.0.1 exits with status 0 when another
  Firefox has the profile open, so quit that Firefox first. One that goes on
  in another process of its group is waited for. A Firefox applying an
  update starts itself again; whether that process stays in the group was
  not measured. The wait ends after 30 seconds.
- Write the table only once a server that reads it is installed:
  `runtime.toml` refuses a key it does not know.

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
   `connectors/browser/install-host.sh` writes the lane token the host and the
   server share (`<base-path>/.masc/browser-lane/token`), a copy of the host
   executable, and the `launch` script used here. The launcher runs that copy
   with this workspace's `--base-path` and token file and passes on what
   follows it, so it does not depend on the `PATH`.

   Adding `--firefox-profile <profile>` makes the host end a session with a
   Firefox on any other profile, as the server-started host does.

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
  - Readers report the actual snapshot count, including longer schema-1
    records. Reaching 64 alone does not prove whether older entries exist
    or archival succeeded; the status names the archive without claiming
    that it exists or succeeded from the count alone.
  - A host that leaves in order adds `ended`: when, why, and
    `session_in_firefox`. A host that could not attach leaves its reason the
    same way.
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
  - `message`: the paragraph the doctor prints.
- A Keeper whose hover or drag is refused as `live_transport_unsupported`
  while no connected browser serves it gets `bidiHost` in the answer, with
  `state` and `message` only, to pass on to the operator. An answer that
  offers a connection in `servingClients` has no `bidiHost`.
- The TUI's Browser Lane picker draws it from the server's `bidiHost`:
  whether a host runs and whether the server lists it, why the last one
  ended, what comes before the next, the results the host holds no
  acknowledgement for, and the command that starts one
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
