# ego browser companion

An optional native browser companion and an observation Lane Add-on. The host
adapter batches known actions, conditional waits and the final semantic snapshot
in one invocation of the installed ego CLI. The isolated worker projects that
captured state into the existing Lane Add-ons surface and named `browser` output.

## Execution boundary

ego is a native macOS application; it does not run in this package's networkless
container. `skills/ego-native/scripts/host.py` must run on the same macOS host as
the installed, onboarded `ego-browser` command. The adapter uses Python 3.11+ and
POSIX file locking. This version does not support Windows host execution.

External coding clients with host command execution can invoke it directly.
An official Claude Keeper on the same host can use native Bash only when its
existing native tool and approval policy permits that. Generic Keeper `Execute`
is sandboxed and cannot invoke this host companion. Installing this package
does not enable native Bash, change approval policy, register a generic host
stdio MCP server, or export host actions as worker tools. Other Keepers can read
the captured output and bundled Skill. This is an observation lane plus explicit
host execution, rather than a new `BrowserSession lane=ego` backend.

The package never imports existing browser data or claims user-owned Spaces.
ego Spaces share their browser profile's cookies; a Space is not account
isolation. Configure the browser profile in ego itself before using sensitive
sites. The adapter exposes named operations, not arbitrary Node.js, CDP or page
evaluation. That does not sandbox the native ego application or the host agent.

## Use the host companion

Choose a private state directory for this installation, outside the checkout.
Use its same absolute path on every call. The directory owns one task space and
serializes all its requests; use another installation for a separate task.
Set `--ego-command /absolute/path/to/ego-browser` if it is not on this process's
PATH. Neither executable nor state location is hardcoded in the package.

```sh
python3 addons/ego-browser/skills/ego-native/scripts/host.py \
  --state-dir /absolute/path/to/ego-state <<'JSON'
{"request_id":"open-project-1","operation":"open","name":"Project browser work"}
JSON
```

The result contains the bound `session.space_id`, URL and snapshot. The native
Space name includes this state directory's durable installation identity, so
different installations using the same display name cannot accidentally share
a Space. Opening the same name while it is active reuses that bound space. A
different name requires finishing the current task first. Reading is explicit:

```json
{"request_id":"read-project-1","operation":"observe","scope":"full_page"}
```

Use a fresh `request_id` for each intended operation. A batch requires the URL
from the previous observation. All steps are validated before invoking ego:

```json
{
  "request_id":"open-report-menu-1",
  "operation":"batch",
  "expected_url":"https://example.test/reports",
  "steps":[
    {"action":"hover","selector":"loc=role:button[name='Reports']"},
    {"action":"wait_for_selector","selector":"text=\"Export CSV\"","state":"visible"},
    {"action":"click","selector":"text=\"Export CSV\""}
  ],
  "expect":{"selector":"text=\"Export ready\"","state":"visible"},
  "screenshot":true
}
```

Selectors may use ego's documented snapshot refs, semantic locators or CSS.
Reuse observed targets. Automatic target scrolling is ego's own implementation.
Supported steps are `goto`, `click`, `dblclick`, `hover`, `drag` (source and
destination selectors), `fill`, `press`, `wait_for_selector` and `wait_for_url`.
Every batch returns the final snapshot for the next decision; no fixed sleep
or automatic retry is added. Requests can select `scope: "full_page"` and a
screenshot. Screenshots remain native files with returned SHA-256 digests;
the observation worker does not fetch or retain those image bytes.

`observed` means APIs returned and a snapshot was read, **not task completion**.
`postcondition_met` means the requested URL/element condition was satisfied.
Choose a condition that demonstrates the actual requested result. A drag API
returning without an exception is insufficient; check the resulting placement.
SDK errors, missing structured replies and unusable results are
`outcome_unknown`, with any available recovery snapshot. A changed initial URL
is `rejected_before_effect`. Do not route around ownership or user-control stops.

After success, finish the task exactly once with a fresh request identity:

```json
{"request_id":"finish-project-1","operation":"finish"}
```

This closes agent-managed Pages through `task.finish({keep:[]})`, preserving
ego's protection for user-created and unmanaged tabs. Do not finish on an error
or user handoff. Observe the same space and resolve its current state instead.

## Receipts and recovery

The adapter syncs a request digest/dispatch record before process creation and
retains its result under `state-dir/receipts`. An identical request ID returns
its retained result without invoking ego again. Different input under the same
ID is rejected. After a crash or lost reply, a dispatched ID with no retained
result returns `outcome_unknown`; it is never replayed. Do not invent a fresh
request ID solely to repeat uncertain input. Observe before deciding a new action.

If the first `open` reply was lost before a space binding could be saved, use a
fresh request with `operation:"recover"`. This lists spaces and resolves only
the installation-owned name retained before dispatch. It creates no Space and
never claims or takes over a user-owned Space. If that exact space is absent,
ambiguous or under user control, it reports uncertainty and needs operator
recovery. A new `open` is refused while that unresolved intent exists.

`open-intent.json` retains first-open ownership; `session.json` retains the bound
space; `snapshot.json` is the latest published
source envelope with request and session identities. A duplicate request does
not overwrite a newer snapshot. A publication/durability failure can leave the
latest lane observation older than the native effect; compare request IDs and
read the retained receipt. Files contain page observations and must stay private.
The journal hashes input without retaining the original fill text; the browser
snapshot can still contain sensitive page content. No receipt storage pruning
or cumulative action limit is imposed.

## Attach the observation lane

Build/load the optional image through the repository's package image workflow:

```sh
docker build -f addons/ego-browser/Dockerfile -t masc-lane-ego-browser:0.1.0 addons
```

Copy [the declaration](../../docs/examples/lane-addons/ego-browser.toml) into the
resolved config root's `lane-addons/` directory. Set an absolute `manifest_path`
to this package and the `snapshot_file` path to the same host adapter state
directory's `snapshot.json`. Ordinary TOML reconciliation then owns the isolated
observer. The image must already exist; saving TOML does not build an image,
install ego or execute the host helper. The existing Add-ons interface presents
the task space, request result, page and captured snapshot. Other packages can
consume its named `browser` output through `lane_output`.

Worker coverage describes the supplied captured observation. It neither polls
the browser nor proves native task completion. The host retains the source
snapshot bytes through the existing `snapshot_file` pipeline. Removing the
observer leaves the native task space alone; finish it explicitly when done.

## Validation

`python3 -m unittest discover -s addons/tests -p test_ego_browser.py -v` checks
the actual host CLI boundary, durable deduplication/lost replies, validation
before effects, serialized callers and observation projection. Its fake native
CLI is a transport fixture. Real ego input, screenshot and outcome evidence is
separate; these tests do not establish container installation, Keeper native
Bash execution, or a reduction in LLM decision turns.
