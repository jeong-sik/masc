# Workspace Curator worker

This optional package retains original classification and briefing executions.
The host owns fact intake, the captured batch and physical workspace, full domain
validation, ledger and briefing commits, observer receipts and wake scheduling.
No provider key, workspace ledger or Keeper memory directory belongs in this
worker. It uses the same `addons/exact_worker.py` storage and MCP implementation
as Candle rather than a second judgment service.

The host first retains its complete `Workspace_memory_execution_capture`. Its
`Server_workspace_memory_addon_validation.request` factory produces the Exact
request accepted by `curate`: original UUID, distinct `classification` or
`briefing` output, original messages and schema. The worker preserves the whole
request; it does not flatten roles, re-render a prompt or substitute a schema.
The shared host Exact runner requires that complete request to match the original
host capture before calling a provider and when replaying an answered result.
The package's baseline and per-request schema grant remain mandatory too.

`curate` accepts `submit` and `read`. Only the host-admitted `operator` envelope
may submit. Other admitted callers can read a known request. `lane_call`,
`lane_host_requests` and `lane_host_result` are private control tools, not agent
exports. A caller cannot grant host semantic authority by submitting JSON here.
The two outputs need existing installation Exact routes; a standalone Curator
route does not attach or configure this package.
Configure them under
`runtime.addon_exact_lanes.<installation-id>.classification` and
`runtime.addon_exact_lanes.<installation-id>.briefing`, using the actual
declaration ID for this installation. Classification and briefing are separate
model selections. The host still owns prompt preparation and semantic admission.

Pending and terminal requests live under the installation's persistent state in
`workspace-curator`. New worker processes read the same original records. An ID
cannot change its input or overwrite its terminal. `outcome_unknown` is terminal
and is never relisted as model work. The shared Exact codec also retains
`output_limit_reached` with its nonblank detail, separately from `invalid_output`.
It never relists that original request. Any whole-batch size successor belongs
to the serialized host owner, not this worker. A failed directory sync stops that writer
from announcing an unconfirmed result; a new owner must inspect original state.
Worker absence or an absent record never grants authority to replay an uncertain
host request. The serialized host owner must make that decision from its journal.

Version 2 stores drop the original input body when retaining any terminal,
keeping its request ID, digest and result. Deploy this revision with the
[worker state hard cut](../../docs/guides/EXACT-WORKER-STATE-HARD-CUT.md).

`lane_host_requests` answers in pages (`[world] host_request_pages = true`). A
page carries pending requests in rising request id order, as many as fit one
reply frame, and nothing beside them. The host passes the last id of a page back
as `after` to get the next page; an empty page ends the listing. A request is
saved when a page that carries it alone fits the manifest's actual reply frame;
other pending requests do not change that answer. A request that
cannot fit such a page ends as the body-free `request_body_refused` result. A
pending request that no page can carry makes its page an error; the listing
never omits pending work silently. Observation exposes pending and finished
counts, request identities where they fit, and an explicit individual read path
otherwise. Finished means the worker retained an Exact terminal; it does not
mean the host committed its ledger or published a complete briefing.

The masc server carries this package. Declare it with `package = "workspace-curator"`,
then run `masc exact-addon-setup --declared --base-path <base-path>`, which writes
the package under `<base-path>/.masc/packages/` and builds its image
([Keeper Librarian install](../../docs/guides/keeper-memory-execution.md#install-the-package)).
State that still holds worker record v1 needs the hard cut above before the move.
A declaration that pins the package with `manifest_path` builds the image from
the repository root instead:

```sh
docker build -f addons/workspace-curator/Dockerfile -t masc-lane-workspace-curator:0.1.7 addons
```

Select this revision with the server stopped, in the order the
[Keeper Librarian upgrade](../../docs/guides/keeper-memory-execution.md#upgrade-an-existing-installation)
gives. This revision names `[world] exact_protocol = 1`.
A server that knows `exact_protocol` refuses a manifest that does not name the
protocol it speaks, and a server that does not know the key refuses this one.
A revision before 0.1.5 answers `capacity_wait`, which a server that
includes [#52731](https://github.com/jeong-sik/masc/pull/52731) no longer reads.

The image includes `exact_worker.py` and `protocol.py` outside the read-only
`/addon` package mount. The normal Runtime owns the worker and `/state` mount.
Neither this image nor the manifest starts a second Curator owner.

Focused actual stdio/restart checks:

```sh
python3 -m unittest discover -s addons/tests -p test_workspace_curator.py
```

`test_workspace_curator_addon_contract` additionally joins host capture, real
worker process restarts, advertised schemas and Hooks, the production semantic
authority and common Exact HTTP flow against loopback providers, and retained
terminal reads. Only the providers are fixtures in that flow. The production
Curator scheduler is not started by this check.

The public production owner now uses the original Addon execution and recovery
path, including actual
configuration/result wakes and fresh configured admission for new work. The
replacement `test_workspace_memory_curator_lane` fixture starts that owner with a
real persistent Python/MCP worker and common Exact loopback providers; resource
launch/cleanup is substituted. Its execution evidence is separate from the
contract-only check above. Original registry publication and Owner ACK recovery
are now connected, including Off maintenance and concurrent strict-store reads.
The selected execution passed 226 cases across ten suites on the exact candidate. It includes
production13 with this Python/MCP/loopback setup; it does not prove actual
provider/container lifecycle or either UI. The candidate's whole tree was merged
into the Candle branch; main integration, current runtime settings/UI cleanup
and installed-runtime evidence remain unfinished E02 work. Extraction completion
is not claimed.
