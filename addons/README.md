# Lane Add-on packages

A package adds observations, relationships, metrics, optional Skills or actions to
an existing MASC run. Its manifest, scripts and execution image supply the domain
behavior; the host supplies installation, source connections, lifecycle, retained
evidence and the common Dashboard. A package can borrow an existing resource or
own its environment. It does not replace a Keeper or make its results a required
step in other Keeper activity.

| Package | Contribution | Resource and state ownership |
| --- | --- | --- |
| [web-project](web-project/) | Relates build expectations, deployment receipts, captured documents and feature probes. | Reads supplied observations; does not create or navigate a browser. |
| [msx-observer](msx-observer/) | Projects captures with the existing MSX frame clock and machine incarnation. | Borrows the native machine through host snapshots; does not send input or own the machine. |
| [output-statistics](output-statistics/README.md) | Counts rows and row kinds in each supplied completed output. | Owns its worker; no cumulative event count or machine state. |
| [frame-progress](frame-progress/README.md) | Measures frame differences between supplied MSX captures. | Keeps a baseline in worker memory; restart or missing input requires a fresh baseline. |
| [value-difference](value-difference/README.md) | Measures signed changes and directions between supplied numeric values, including DOS counters. | Keeps independent source baselines in worker memory; owns no upstream machine. |
| [dos-world](dos-world/README.md) | Runs a homebrew DOS counter, accepts an optional action and emits guest-state and screen artifacts. | Owns its DOS/WASM machine inside its worker; replacement starts a new machine. |

Removing an observer or metric package leaves the source owner intact. Removing
the DOS package ends its own environment through its worker lifecycle. The host
retains committed output and host-owned evidence after either kind of removal.

## Install and connect

The package's `lane.toml` declares its image, command, contributions, resource
envelope and optional `world` connections. A separate workspace declaration
selects the package with `id`, `run_id`, `manifest_path` and `[binding]`.

Prepare the image in CI and load it into the Docker engine used by MASC. Place the
package where MASC can read its manifest and bundled Skills, then save the
workspace declaration under `<resolved-config-root>/lane-addons/`. Resolve
`manifest_path` relative to that declaration's location. Existing reconciliation
installs, updates and removes its worker; a separate manual Attach request is not
required. Saving TOML does not build or download the environment, and desired
configuration is distinct from applied revision and successful observation.
See [TOML installation](../docs/guides/lane-addon-toml.md), the
[MSX declaration](../docs/examples/lane-addons/msx-frames.toml) and
[DOS declaration](dos-world/install.toml).

[Output composition](../docs/guides/lane-output-composition.md) connects a
consumer's `binding.sources` to another installation in the same run using
`kind = "lane_output"` and `selection = "latest_completed"`.
[Named outputs](../docs/guides/lane-output-ports.md) let that source select an
`output_id` declared by the producer: MSX publishes `frames`, DOS publishes
`guest`, value-difference publishes `difference`, and statistics publishes
`statistics`. Unknown names are unavailable;
a known port with no matching rows is an empty supplied output. Original row
identities and whole-producer coverage remain attached to the selected evidence.

The [package image workflow](../.github/workflows/lane-addon-images.yml) discovers
package Dockerfiles. The [DOS workflow](../.github/workflows/lane-dos-package.yml)
also exercises the guest and retains its measured artifacts. These are example
image build commands for CI, using the repository root and `addons` build context:

```sh
docker build -f addons/web-project/Dockerfile -t masc-lane-web-project:0.1.0 addons
docker build -f addons/msx-observer/Dockerfile -t masc-lane-msx-observer:0.1.0 addons
```

Each manifest specifies its worker's resource envelope. The Web, MSX, statistics,
frame-progress and value-difference examples use half a CPU, 128 MiB memory,
16 processes and a
4 MiB maximum reply; DOS uses one CPU, 512 MiB, 64 processes and the same reply
bound. These apply to package environments, not Keeper activity. Qualification
records the applied envelope and measured impact; declarations alone do not
constitute performance acceptance.

The worker publishes its exact container ID before inspection and MCP
initialization, so those operations can be interrupted by explicit detach.
Cleanup is verified only after a successful Docker query confirms that the exact
container is absent. After a host restart, recovery verifies the retained
container ID and ownership label before removal. If the create receipt has no
container ID, recovery finds this instance's deterministic container name,
verifies the exact name and ownership label, and removes the resolved ID.
An unavailable Docker daemon or mismatched ownership leaves cleanup incomplete.
Package lifecycle tests cover blocked inspection, initialization, observation,
and lost-receipt recovery; CI and live qualification establish the actual result.

## Skills and optional actions

MSX, frame-progress and DOS declare `[world.skills] directory = "skills"`.
Their bundled instructions and script/reference resources join the existing
workspace Skill catalog as read-only sources. `keeper_skill` reads selected
bytes and reports their identity; resource reads report a separate SHA-256.
Reading a helper does not execute it, add controls or force instructions into a
Keeper turn. Sources use the existing configured Skill resource-read bound and
selection rules. The installation guide describes this read path.

Installing a package does execute its declared `command` in its worker. A
package can additionally declare `act` and `[world.actions] tool = "lane_act"`
to accept explicit requests through the common action surface. Request receipts
distinguish durable acceptance, dispatch and the package's reported outcome;
confirmation still needs its stated evidence. The
[world connection and action contract](../docs/guides/lane-world-actions.md)
describes incarnation checks, request identity and retained artifacts.
Observation and derivation packages need no action port.

## Worker protocol and package tests

Every worker advertises `lane_observe` through MCP `tools/list`. Ordinary
observation requests contain `{binding, sources}`; acting workers also receive
the host's instance/incarnation `context`. Observations return `rows` and
`coverage` in `structuredContent`. Any package may include the optional
`artifacts` bytes envelope; it does not require an action contribution. The host
computes and retains artifact hashes without fetching arbitrary artifact URIs.

The Python observation/derivation packages use `protocol.py` for MCP stdio
framing and common row helpers. They advertise input and output schemas and
also return a JSON text projection. DOS uses the MCP SDK and returns structured
content without duplicating its artifact bytes in text. The host negotiates
protocol revision 2025-06-18. Package-specific processing remains in each worker.

Run the Python package feature tests without building OCaml or an image:

```sh
python3 -m unittest discover -s addons/tests -v
```

These tests execute the Python stdio workers and cover Web counterexamples,
source coverage, actor provenance, MSX incarnations, supplied-row statistics and
frame differences. The HTTP test measures served HTML with fixture client and
document identities. Actual DOS execution has its separate package workflow.
Package tests alone do not establish browser/Keeper action, Docker isolation,
live MSX behavior or performance acceptance. The linked guides distinguish
qualified host/package revisions from production deployment.

## Sources

The host supplies immutable source snapshots, including coverage:

```json
{
  "source_id": "browser-events",
  "incarnation": "session-1",
  "cursor": "offset:42",
  "complete": true,
  "detail": null,
  "observations": []
}
```

An observation carries `id`, epoch `observed_at`, `actor` (actual observer or
executor, otherwise null), and `evidence: [{uri, sha256}]`. Digests are lowercase
SHA-256 or null. A deployment's assigned runtime never substitutes for actor.
Event IDs are namespaced by source and incarnation when projected into rows.
Rows reference source evidence. The host retains acquired source/output blobs
and supplied artifact bytes. An external URI reference alone does not establish
that its destination bytes were copied into host storage.

For the Web and MSX projectors, unrecognized observation kinds, including raw
Keeper records, produce no domain claims. Coverage identifies the ignored kinds
and preserves the source's own completeness, cursor, and missing-range detail. Known kinds with malformed
required fields return a tool error, without invented default observations.

## Web binding and observations

```json
{
  "target": {"id": "store", "environment": "production", "url": "https://store.example/app"},
  "request_id": "verify-build-A",
  "expected": {
    "namespace": "store-build",
    "revision": "A",
    "observed_at": 1789034400.0,
    "manifest": {"uri": "artifact://build/A/manifest.json", "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
  }
}
```

The expectation is a distinct row with the timestamp of the recorded build
expectation, not the browser timestamp. `manifest.sha256` is required to identify
its immutable evidence. The example digest is illustrative, not measured proof.

Each Web observation additionally carries `target` with the *actual* target ID,
environment, and URL, and `request_id`. Match uses all these coordinates exactly.
Keep query strings, ports, and paths. Do not relabel observed coordinates with
the requested coordinates. Kind-specific fields are:

| Kind | Required additional fields |
| --- | --- |
| `deployment` | `revision` recorded in the deployment receipt |
| `browser` | `client_id`, `tab_id`, `document_id`, `html` (same-document HTML, or null) |
| `probe` | `client_id`, `tab_id`, `document_id`, `passed` (boolean) |

The browser producer must capture actual URL, document identity, and HTML from
the same existing document. An independent HTTP request, source checkout hash,
or `/version` endpoint is not a substitute. The package does not navigate the
browser to obtain missing data. The document head has explicit markers:

```html
<head>
<meta name="masc-revision" content="B">
<meta name="masc-revision-namespace" content="store-build">
</head>
```

HTMLParser extracts active document-head markers; body content, templates,
noscript and title content cannot declare the build. Missing, duplicate,
ambiguous, or noncomparable namespace markers yield unknown.
A relation claims only what that browser document showed
at its observation time. Probes join only with matching target, request, client,
tab, and document. A failing probe with matching revision remains a feature
failure. Matching deployment receipts join as reported claims, without replacing
the actual document observation. Unrelated observations remain raw rows and
yield no relation.

## MSX binding and observations

Binding is `{ "machine_id": "workspace-msx" }` to follow the existing machine
across explicitly recorded histories. Optional `incarnation: "load-2"` pins one
history; absent or null means any observed incarnation, not an invented ID.
Each `capture`
observation adds `machine_id`, `incarnation`, nonnegative integer `frame`,
`screen: {uri, sha256}`, and nullable `input_cursor`. Incarnation must change when
loading/restoring a machine history so a reset frame is not mistaken for an
earlier point in the same clock. The package preserves every supplied capture
and indicates whether it matches the binding. It never derives game-state facts
from screen filenames or silently turns a Keeper turn into an MSX frame.
